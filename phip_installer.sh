#!/usr/bin/env bash

set -Eeuo pipefail
log(){ printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

log "Loading required environment modules..."
if ! command -v module >/dev/null 2>&1; then
  for f in /etc/profile.d/modules.sh /usr/share/Modules/init/bash; do
    [[ -f "$f" ]] && . "$f"
  done
fi
module load r/3.6.3 >/dev/null 2>&1 || module load r/4.0.2 >/dev/null 2>&1 || die "Cannot load R (3.6.3 or 4.0.2)"
module load curl/7.83.0  >/dev/null 2>&1 || die "Cannot load curl/7.83.0"
module load bzip2/1.0.8  >/dev/null 2>&1 || true
module load libjpeg/9c    >/dev/null 2>&1 || true
module load libpng/1.6.37 >/dev/null 2>&1 || true

command -v curl-config >/dev/null 2>&1 || die "curl-config not found after loading curl/7.83.0"
CURL_CFG="$(command -v curl-config)"
CURL_PREFIX="$(curl-config --prefix)"
log "curl-config: ${CURL_CFG}"
log "libcurl: $(curl-config --version)"

export PKG_CONFIG_PATH="${CURL_PREFIX}/lib/pkgconfig:${CURL_PREFIX}/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="${CURL_PREFIX}/lib:${CURL_PREFIX}/lib64:${LD_LIBRARY_PATH:-}"
log "PKG_CONFIG_PATH=${PKG_CONFIG_PATH}"
log "LD_LIBRARY_PATH=${LD_LIBRARY_PATH}"

command -v Rscript >/dev/null 2>&1 || die "Rscript not in PATH"
R_FULL="$(Rscript --vanilla -e 'rv<-R.version; cat(paste(rv$major, rv$minor, sep="."))' || true)"
[[ -n "${R_FULL}" ]] || die "Could not read R version"
log "Detected R version: ${R_FULL}"

case "${1:-}" in
  -h|--help)
    echo "Usage: $0 [custom_R_lib_path]"
    echo "If omitted, defaults to: \$HOME/rlibs/${R_FULL}/gcc/9.3.0"
    exit 0
    ;;
esac
if [[ -n "${1:-}" ]]; then
  export R_LIBS_USER="$1"
else
  export R_LIBS_USER="${HOME}/rlibs/${R_FULL}/gcc/9.3.0"
fi
mkdir -p "${R_LIBS_USER}"
log "R user library: ${R_LIBS_USER}"

SNAP="https://packagemanager.posit.co/cran/2021-06-15"
if curl -fsI "${SNAP}/src/contrib/PACKAGES.gz" >/dev/null 2>&1; then
  CRAN="${SNAP}"
  log "Using CRAN snapshot: ${CRAN}"
else
  CRAN="https://cloud.r-project.org"
  log "Snapshot unreachable; falling back to CRAN: ${CRAN}"
fi
export CRAN

export MAKEFLAGS="-j1"
export PKG_BUILD_NCPUS="1"

TMP_PARENT="/tmp"
mkdir -p "${TMP_PARENT}/${USER}" || die "Cannot create ${TMP_PARENT}/${USER}"

TMPDIR="$(mktemp -d "${TMP_PARENT}/${USER}/r-tmp-XXXXXX")" || die "mktemp failed"
export TMPDIR

log "TMPDIR: ${TMPDIR}"
log "MAKEFLAGS=${MAKEFLAGS}, PKG_BUILD_NCPUS=${PKG_BUILD_NCPUS}"
trap 'rm -rf "${TMPDIR}" || true' EXIT

set +e
Rscript --vanilla - <<'RS'
opt_repo <- Sys.getenv("CRAN")
options(repos = c(CRAN = opt_repo), Ncpus = 1L)
Sys.setenv(R_REMOTES_NO_ERRORS_FROM_WARNINGS="true")

lib_user <- Sys.getenv("R_LIBS_USER")
dir.create(lib_user, recursive=TRUE, showWarnings=FALSE)
.libPaths(c(lib_user, .libPaths()))

cat("[R] R.version: ", R.version$major, ".", R.version$minor, "\n", sep="")
cat("[R] .libPaths:\n  ", paste(.libPaths(), collapse="\n  "), "\n", sep="")
cat("[R] CRAN repo: ", getOption("repos")[["CRAN"]], "\n", sep="")
cat("[R] TMPDIR: ", Sys.getenv("TMPDIR"), "\n", sep="")

success <- character(); failed <- character()
mark_ok <- function(pkg) success <<- c(success, sprintf("%s %s", pkg, as.character(utils::packageVersion(pkg))))
mark_fail <- function(pkg, e) { message("[FAIL] ", pkg, ": ", conditionMessage(e)); failed <<- c(failed, pkg) }

dep_types <- c("Depends","Imports","LinkingTo")

install_cran <- function(pkg, version=NULL, configure.args=NULL) {
  tryCatch({
    if (is.null(version)) {
      if (is.null(configure.args)) {
        install.packages(pkg, dependencies=dep_types)
      } else {
        install.packages(pkg, dependencies=dep_types, configure.args=configure.args)
      }
    } else {
      if (!requireNamespace("remotes", quietly=TRUE))
        install.packages("remotes", dependencies=dep_types)
      if (is.null(configure.args)) {
        remotes::install_version(pkg, version=version, dependencies=dep_types, upgrade="never")
      } else {
        remotes::install_version(pkg, version=version, dependencies=dep_types, upgrade="never",
                                 configure.args=configure.args)
      }
    }
    if (!requireNamespace(pkg, quietly=TRUE)) stop("not found after install")
    mark_ok(pkg)
  }, error=function(e) mark_fail(pkg, e))
}

# remotes (bootstrap)
install_cran("remotes")

# curl with rpath; fallback to 4.3.2 if runtime symbol issues
cfg <- Sys.which("curl-config")
rpath_dir <- normalizePath(file.path(dirname(dirname(cfg)), "lib"), mustWork=FALSE)
if (dir.exists(rpath_dir)) {
  old_ld <- Sys.getenv("LDFLAGS", "")
  Sys.setenv(LDFLAGS = paste("-Wl,-rpath,", rpath_dir, " ", old_ld, sep=""))
}
need_curl <- TRUE
if (requireNamespace("curl", quietly=TRUE)) {
  ok <- tryCatch({ curl::curl_version(); TRUE }, error=function(e) FALSE)
  if (ok) { need_curl <- FALSE; mark_ok("curl") }
}
if (need_curl) {
  install_cran("curl", configure.args=sprintf("--with-curl-config=%s", cfg))
  ok <- FALSE
  if (requireNamespace("curl", quietly=TRUE)) {
    ok <- tryCatch({ curl::curl_version(); TRUE }, error=function(e) { message("[curl] load error: ", e$message); FALSE })
  }
  if (!ok) {
    message("[curl] Falling back to curl 4.3.2 from CRAN Archive …")
    tryCatch({
      if ("curl" %in% rownames(installed.packages())) remove.packages("curl")
      install.packages("https://cran.r-project.org/src/contrib/Archive/curl/curl_4.3.2.tar.gz",
                       repos=NULL, type="source", dependencies=dep_types)
      if (!requireNamespace("curl", quietly=TRUE)) stop("curl 4.3.2 not installed")
      curl::curl_version()
      mark_ok("curl")
    }, error=function(e) mark_fail("curl_4.3.2", e))
  }
}

# Core CRAN set (snapshot)
for (p in c("R.utils","data.table","igraph","foreach","doParallel","future","future.apply","tidyverse","plotly","fitdistrplus", "janitor")) {
  install_cran(p)
}

## --- dplyr >= 1.1.0 (override snapshot; fallback to Archive) -----------------
need_dplyr <- TRUE
if (requireNamespace("dplyr", quietly = TRUE)) {
  cur <- as.character(utils::packageVersion("dplyr"))
  need_dplyr <- utils::compareVersion(cur, "1.1.0") < 0
}
if (need_dplyr) {
  if (!requireNamespace("remotes", quietly = TRUE))
    install.packages("remotes", repos = "https://cloud.r-project.org", lib = lib_user)
  ok <- TRUE
  tryCatch({
    remotes::install_version(
      "dplyr", version = "1.1.0",
      repos        = "https://cloud.r-project.org",             # override snapshot
      dependencies = c("Depends","Imports","LinkingTo"),
      upgrade      = "always",                                   # bump rlang/vctrs/tibble if needed
      lib          = lib_user
    )
  }, error = function(e) {
    message("[dplyr] install_version failed: ", e$message)
    ok <<- FALSE
  })
  if (!ok || !requireNamespace("dplyr", quietly = TRUE) ||
      utils::compareVersion(as.character(packageVersion("dplyr")), "1.1.0") < 0) {
    message("[dplyr] Falling back to CRAN Archive tarball …")
    install.packages(
      "https://cran.r-project.org/src/contrib/Archive/dplyr/dplyr_1.1.0.tar.gz",
      repos = NULL, type = "source", lib = lib_user
    )
  }
}
if (!requireNamespace("dplyr", quietly = TRUE) ||
    utils::compareVersion(as.character(packageVersion("dplyr")), "1.1.0") < 0) {
  stop("dplyr < 1.1.0 after install attempts")
}

# locfit exact (Archive)
if (!requireNamespace("locfit", quietly=TRUE)) {
  tryCatch({
    install.packages("https://cran.r-project.org/src/contrib/Archive/locfit/locfit_1.5-9.4.tar.gz",
                     repos=NULL, type="source", dependencies=dep_types)
    if (!requireNamespace("locfit", quietly=TRUE)) stop("locfit not installed")
    mark_ok("locfit")
  }, error=function(e) mark_fail("locfit", e))
} else mark_ok("locfit")

# Bioconductor
if (!requireNamespace("BiocManager", quietly=TRUE)) install_cran("BiocManager")
if (requireNamespace("BiocManager", quietly=TRUE)) {
  for (bp in c("edgeR","Rsubread","Rsamtools","ShortRead")) {
    tryCatch({
      BiocManager::install(bp, ask=FALSE, update=FALSE, quiet=TRUE)
      if (!requireNamespace(bp, quietly=TRUE)) stop("not found after Bioc install")
      mark_ok(bp)
    }, error=function(e) mark_fail(bp, e))
  }
} else {
  message("[WARN] BiocManager unavailable; skipping Bioc packages")
  failed <- c(failed, "edgeR","Rsubread","Rsamtools","ShortRead")
}

# GitHub
if (requireNamespace("remotes", quietly=TRUE)) {
  for (repo in c("ropensci/drake", "brandonsie/phipmake", "jernbom/ARscore")) {
    pkg <- sub(".*/","",repo)
    tryCatch({
      remotes::install_github(repo, upgrade=FALSE, dependencies=dep_types, build_vignettes=FALSE)
      if (!requireNamespace(pkg, quietly=TRUE)) stop("not found after install_github")
      mark_ok(pkg)
    }, error=function(e) mark_fail(pkg, e))
  }
} else {
  message("[WARN] remotes not installed; skipping GitHub packages")
  failed <- c(failed, "drake","phipmake")
}

# Summary
message("\n=== Installation summary ===")
message("Success (", length(success), "): ", if(length(success)) paste(success, collapse=", ") else "none")
message("Failed  (", length(failed),  "): ", if(length(failed))  paste(failed,  collapse=", ") else "none")

# Core load test (must pass for success)
core <- c("Rsubread","Rsamtools","ShortRead","foreach","doParallel","data.table","R.utils","curl")
bad <- character(0)
for (p in core) {
  ok <- suppressWarnings(require(p, character.only=TRUE, quietly=TRUE))
  if (!ok) bad <- c(bad, p)
}
if (length(bad)) {
  message("[ERROR] Core packages failed to load: ", paste(bad, collapse=", "))
  quit(status = 2L)
} else {
  message("[OK] Core packages loaded; environment is ready.")
}
RS
rc=$?
set -e

if [[ $rc -eq 0 ]]; then
  log "=== DONE: environment installed in ${R_LIBS_USER} ==="
  log "To use later:"
  echo "  module load r/3.6.3"
  echo "  export R_LIBS_USER='${R_LIBS_USER}'"
  echo "  # then run your pipeline as-is"
  exit 0
else
  log "Installer encountered errors (rc=$rc). See output above."
  exit $rc
fi

