## Installation

To run the **phipDB** pipeline, you must install several version-specific modules and R packages. This is handled automatically by the `phip_installer.sh` script.

The installer script is located here on github and on Rockfish at:
```bash
/home/$USER/data_hlarman1/PhIPdb/Software/Phipseq_dependencies
```
By default, all required R libraries are installed into the user’s local R library path. The script also accepts an optional argument pointing to a custom writable directory where you would like the libraries to be installed.

## Run the installer

```bash
chmod a+x phip_installer.sh
./phip_installer.sh [optional: /custom/path/to/dir]
```
* If no path is provided, libraries are installed to the default $USER local R library.
* If a path is provided, libraries are installed to that custom directory.

## Verify the installation
A helper script, phip_verify.sh, is provided to confirm that all required dependencies were installed correctly.
```bash
chmod a+x phip_verify.sh
./phip_verify.sh
```
## Using a custom R library path
If you installed R libraries to a custom directory, you must set `R_LIBS_USER` so that R (and the pipeline) can find those dependencies.
For interactive shells:
```bash
export R_LIBS_USER="/path/to/custom/lib/"
```
For `SLURM` `sbatch` calls, you can export `R_LIBS_USER` as part of the job submission, for example:
```bash
sbatch --export=R_LIBS_USER="/path/to/custom/lib/" 
```
