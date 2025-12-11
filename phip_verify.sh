#!/usr/bin/env bash
set -euo pipefail

#module load r/4.0.2 >/dev/null 2>&1 || module load r/3.6.3
module load r/3.6.3
module load curl/7.83.0 bzip2/1.0.8 libjpeg/9c libpng/1.6.37 >/dev/null 2>&1 || true

R_FULL="$(Rscript --vanilla -e 'rv<-R.version; cat(paste(rv$major, rv$minor, sep="."))')"
export R_LIBS_USER="${HOME}/rlibs/${R_FULL}/gcc/9.3.0"

Rscript --vanilla - <<'RS'
lib_user <- Sys.getenv("R_LIBS_USER")
.libPaths(c(lib_user, .libPaths()))

cat("R: ", R.version.string, "\n", sep="")
cat(".libPaths():\n  ", paste(.libPaths(), collapse="\n  "), "\n\n", sep="")

pkgs <- c(
  "R.utils","data.table","igraph","foreach","doParallel","plotly","curl",
  "future","future.apply","tidyverse","locfit","remotes",
  "edgeR","Rsubread","Rsamtools","ShortRead",
  "drake","phipmake"
)
ip <- as.data.frame(installed.packages(), stringsAsFactors = FALSE)
have <- intersect(pkgs, ip$Package)
miss <- setdiff(pkgs, ip$Package)

if (length(have)) {
  cat("Installed (", length(have), "):\n", sep="")
  for (p in sort(have)) {
    cat(sprintf("  %-12s %s  [%s]\n", p, ip[ip$Package==p,"Version"], ip[ip$Package==p,"LibPath"]))
  }
} else cat("Installed (0):\n")

if (length(miss)) {
  cat("\nMissing (", length(miss), "): ", paste(sort(miss), collapse=", "), "\n", sep="")
} else cat("\nMissing (0): none\n")

# Load tests
core <- c("Rsubread","Rsamtools","ShortRead","foreach","doParallel","data.table","R.utils")
ok_all <- TRUE
cat("\nLoad tests:\n")
for (p in core) {
  cat(sprintf("  %-12s ... ", p))
  if (!suppressWarnings(require(p, quietly=TRUE, character.only=TRUE))) {
    cat("FAIL\n"); ok_all <- FALSE
  } else {
    cat("OK\n")
  }
}
cat("  curl         ... ")
if (suppressWarnings(require(curl, quietly=TRUE))) {
  cv <- tryCatch(curl::curl_version(), error=function(e) e)
  if (inherits(cv, "error")) { cat("FAIL: ", cv$message, "\n", sep=""); ok_all <- FALSE
  } else { cat("OK (libcurl ", cv$version, ")\n", sep="") }
} else { cat("FAIL: package not installed\n"); ok_all <- FALSE }

cat("\n")
sessionInfo()
quit(status = if (ok_all && length(miss)==0) 0 else 2)
RS

