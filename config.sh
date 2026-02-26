#!/bin/bash

# Binary and atlas locations
export FETALREF=/home/ch162835/work/dataverse/CRL2025Atlas/t2w

# Default template image list
# You can add additional atlas/reference images to the list
tlist="${REPO}/tlist.txt"

# # # SUFFIXES OF DEFAULT ATLAS LABELS # #
# Tissue = standard tissue seg
# tissueWMZ = with subplate and intermediate zone, normally only used for GA < 32 weeks
# region = regional segmentation (cortical parcellation)
AllLabs="tissue tissueWMZ regional"
# # # # # # # # # # # # # # # # # # # # # #

# # # Set segmentation to ON or OFF # # #
# You can disable this setting if you only want the registrations to happen
segmentation="ON"
# # # # # # # # # # # # # # # # # # # # #
LCP="112" # Cortical plate label used to test PVC output behavior
# # # # # # # # # # # # # # # # # # # # #
