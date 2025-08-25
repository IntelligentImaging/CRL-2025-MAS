# CRL-2025-MAS

# Multi-atlas segmnetation (MAS) pipeline script usage
* First, rigidly register T2-weighted reconstructions to CRL atlas space with your registration tool of choice.

Command:
`sh MAS-pipeline.sh [Imagelist] [OutputDir] [MaxThreads]`<br>
  - Image list is a path list of atlas-space T2-weighted reconstructions and their gestational ages (GA, rounded to whole number weeks), for example:
  > /workdir/CASE001_t2w.nii.gz 34 <br>/workdir/CASE002_t2w.nii.gz 22<br>/workdir/CASE003_t2w.nii.gz 29<br>/workdir/CASE004_t2w.nii.gz 36
  - Default settings will generate both tissue and regional segmentations
  - Runs partial volume correction (PVC) on the *tissue segmentation* (--noPVC argument to disable) 

 Output directory organization:
 > OutputDir/CASE001_t2w <br>
   template_rT: Temp files; non-rigid registrations of atlas images to the target image (and warped segmentations)<br>
   log: Records the command and input files for each segmentation<br>
   seg: Output segmentations<br>
   calc: If available, crosses tissue and regional segmentation to attempt a parcellated tissue segmentation<br>

# Modifying atlas images
You can swap or add atlas images to the atlas directory specified at the top of `MAS-pipeline.sh`, just make sure the filename of each file ends in `_atlas.nii.gz`.<br>
The script matches each `_atlas` file with corresponding segmentations, by default these are `tissue`, `tissueWMZ` and `regional`.<br>
Specify a custom label scheme like `-l YourLabelSuffix`<br>
You can change the output naming of the segmentation files with `-p YourOutputPrefix`

# CRL Toolkit (CRKit) Download
You can download CRKit, including STAPLE and other image maniuplation binaries utilized in these scripts, from NITRC:
https://www.nitrc.org/projects/staple

There's also a Docker container available with CRKit installed:
https://github.com/sergeicu/crkit-docker
Mileage may vary.