#!/bin/bash

# Fetal MRI segmentation pipeline script
#
# This script takes input lists for INPUTS, TEMPLATE IMAGES, and TEMPLATE IMAGE LABELS,
# does a series of registrations with ANTS, and then runs STAPLE segmentation using the registered
# images as the segmentation atlases. The script only uses template images that are
# within +/-1 week gestational age of the input. INPUTS needs to be masked, registered,
# and intensity corrected. Output parcellation is put into OutputDir/seg/.
# "PVC" stands for partial volume correction and will be placed into
# OutputDir/PVC/ (requires crlCorrectFetalPartialVoluming).
# 
# Clemente Velasco-Annis, 2016, 2025"
# clemente.velasco-annis@childrens.harvard.edu"

shopt -s extglob

# Binary/program directories
# Set env variables
#export FETALREF=/PATH/TO/CRL2025Atlas
export FETALREF=/home/ch162835/work/CRL2025Atlas
#export CRKIT=/PATH/TO/CRKIT
export CRKIT=/home/ch162835/fetalmri/software/crkit

# Default STA atlas list, found in this repository # # # # # # # # # 
REPO=`dirname $0`
tlist="${REPO}/tlist.txt"
# You can add additional atlas reference images to this list

# # # PREFIXES OF DEFAULT ATLAS LABELS # #
# Tissue = standard tissue seg
# tissueWMZ = with subplate and intermediate zone, normally only used for GA < 32 weeks
# region = regional segmentation (cortical parcellation)
AllLabs="tissue tissueWMZ regional"
# # # # # # # # # # # # # # # # # # # # # #

# # # Set segmentation to ON or OFF # # #
# You can disable this setting if you only want the registrations to happen
segmentation="ON"                       
# # # # # # # # # # # # # # # # # # # # #
PartialVolumeCorrection="ON"
LCP="112" # Cortical plate label used to test PVC output behavior
# # # # # # # # # # # # # # # # # # # # #

# Arguments and help message
show_help () {
cat << EOF
    ----------------------------------------------------------
    Incorrect arguments supplied!
    Usage: sh ${0} [-h] [-a AtlasList.txt -l AtlasLabelsPrefix] [-p OutputSegPrefix] -- [Imagelist] [OutputDir] [MaxThreads]
    
        -h      display this help and exit
        -a      supply a structual ATLAS text list, formatted like:
                    PATH/t2w_GA30_atlas.nii.gz 30
                    PATH/t2w_GA31_atlas.nii.gz 31 ... etc
        -l      [required if -a is specified] specify atlas label suffix. Label files need to be in the same directory as atlases and named like:
                    PATH/t2w_GA30_SUFFIX.nii.gz
                    PATH/t2w_GA31_SUFFIX.nii.gz ...etc
                    (defualt: all three of tissue, tissueWMZ, and regional)
        -p      specify output segmentation prefix (default: mas)

        [Imagelist] A text file with a list of input images formatted with one image per row and GA, i.e.
                    PATH/image01.nii.gz 32
                    PATH/image02.nii.gz 29 ...etc
        [OutputDir] Output directory for all working files and output segmentations
        [MaxThreads] Maximum number of CPUs for running concurrent registrations and multi-threaded STAPLE (usually 8-12)
EOF
}

die() {
    printf '%s\n' "$1" >&2
    exit 1
}

# Parsing optional arguments
while :; do
    case $1 in
        -h|-\?|--help)
            show_help # help message
            exit
            ;;
        -a)
            if [[ -f "$2" ]] ; then
                tlist=$2 # replaces default template image list with user argument
                shift
            else
                die 'error: "-a" requires a text list of atlases'
            fi
            ;;
        -l)
            if [ -n "$2" ] ; then
                userlabs=$2 # script will replace default atlas prefixes with this
                shift
            else
                die 'error: "-l" requires a label prefix (the rest of the filename should match the atlas)'
            fi
            ;;
        -p)
            if [ -n "$2" ] ; then
                OutputPrefix=$2
                shift
            else
                die 'error: "-p" requires prefix be specified'
            fi
            ;;
        --) # end of optionals
            shift
            break
            ;;
        -?*)
            printf 'warning: unknown option (ignored: %s\n' "$1" >&2
            ;;
        *) # default case, no options
            break
    esac
    shift
done

# Parse required inputs
if [ ! $# = 3 ] ; then
    show_help
    exit
fi

# Assign arguments
inputs="$1"
outdir="$2"
NThreads="$3"

function depchk () {
        if command -v $1 >/dev/null 2>&1 ; then
            echo "$1 found"
            #echo "version: $($1 --version)"
        else
            echo "$1 not found"
            exit 1
        fi
        }



# If optional atlas labels given, use those instead of the default found in FETALREF
if [[ -n $userlabs ]] ; then
    AllLabs="$userlabs"
fi

# Checking that input list is a text file
inputsType=$(file "$inputs")
if ! [[ $inputsType == *":"*"text"* ]] ; then
	echo "error: argument #1 (inputs) was not a text file." 
	echo "Should be a text file formatted: [IMAGE] [GA]"
    exit 1
fi

# Checking that template list is a text file
tlistType=$(file "$tlist")
if [[ ! $tlistType == *":"*"text"* ]] ; then
	echo "Atlas T2 list not found or is not a text file."
	exit 1
fi

# Check that template structural images exist
CheckTemplates=""
while read CHECK ; do
	path=${FETALREF}/`echo $CHECK | awk -F' ' '{ print $1 }'`
	if [[ ! -f $path ]] ; then
		CheckTemplates="ERROR"
		echo "error: $path doesn't exist"
	fi
done < $tlist
if [[ "$CheckTemplates" = "ERROR" ]] ; then
	echo "Couldn't find template(s). Check the paths in template list."
    echo "You may be able to set symbolic links to make this work"
    exit 1
fi

# Checking ouput segmentation prefix syntax
if [[ "$OutputPrefix" == *\/* ]] || [[ "$OutputPrefix" == *\\* ]] ; then
	echo "Don't put a slash character in the OutputPrefix (\$5)! It is no bueno."
	exit 1
fi

# Checking number of threads is a natural number
re='^[0-9]+$'
if ! [[ $NThreads =~ $re && $NThreads -ne 0 ]] ; then
    echo "error: argument six (MaxThreads) was not a natural number." >&2; exit 1
fi
# # # Finished checking arguments and variables # # #

# # # Case directory setups begin # # # 
echo "Making case directory, setting some variables, starting template propagation..."
# Create output DIR and copy scripts and binaries
mkdir -pv "$outdir"
tools="${outdir}/tools" # we save some files here for archival reasons
mkdir -pv "$tools"
cp $0 -v --update=none ${tools}/seg.sh # make a copy of this script
cp ${tlist} -v ${tools}/ # copy the input template list

source ${CRKIT}/bin/crkit-env.sh
SEG="${CRKIT}/bin/crlProbabilisticGMMSTAPLE" # STAPLE binary
MATH="${CRKIT}/bin/crlImageAlgebra" # Used for parcellating cortical plate
PVC="${REPO}/bin/crlCorrectFetalPartialVoluming" # Partial Volume Correction binary
VOL="${REPO}/bin/crlComputeVolume" # Used for checking PVC output
baseTLIST=`basename $tlist`
TLIST="${tools}/${baseTLIST}"

# Default output segmentation prefix
if [ -n $OutputPrefix] ; then
    OutputPrefix="MAS"
fi

# Check dependencies
depchk ANTS
depchk $SEG
depchk $PVC
depchk $VOL
depchk $MATH



# Begin 'for loop' for each atlas segmentation scheme
# default labels are specified at top of script
# defaults are GEPZ, GEPZ-WMZ, and regions
for lsuffix in $AllLabs ; do
    echo
    echo "## Process registrations for all cases for atlas segmentation $lsuffix ##"
    OutPre2="${OutputPrefix}-${lsuffix}"

    # Atlas registration loop for all input cases
    while read line; do 
        echo
        image=`readlink -f $(echo $line | awk -F' ' '{ print $1 }')`
        echo "# Input case information #"
        echo "time : `date`"
        echo "image : ${image}"
        echo "atlas seg: ${lsuffix}"
        if [[ ! -f ${image} ]] ; then
            echo "  ERROR: ${image} not found! Check path"
            echo "  Skipping to next input"
            echo
            continue
        fi

        # Record gestational age range for deciding atlas references
        GA=`echo $line | awk -F' ' '{ print $2 }'`
        if [[ $GA -eq "" ]] ; then
            echo "  ERROR: Input ${image} had no GA specified. Please add GA as second column of input list and try again."
            echo "  Skipping to next input"
            echo 
            continue
        fi
        GAm=`expr $GA - 1`
        GAp=`expr $GA + 1`
        echo "Gestational Age : $GA"
        echo

        # Finish setting up case directory
        name=`echo $(basename $image) | awk -F'.' '{ print $1 }'`
        caseout="${outdir}/${name}"
        mkdir -pv ${caseout}/log
        # Copy of input case text list for this case only
        echo "$line" > ${caseout}/log/inputGA-${OutPre2}_${GA}.txt
        # "Run" script for this case only
        echo "sh ${tools}/seg.sh -a ${TLIST} -l "${AllLabs}" -p ${OutPre2} ${caseout}/log/inputGA-${OutPre2}_${GA}.txt ${outdir} ${NThreads}" > ${caseout}/log/run-${OutPre2}_${name}.sh
        # Registered images and labels go here
        mkdir -pv ${caseout}/template_rT
        # Make a copy of the input image
        cp ${image} -v --update=none ${caseout}/
        
        # Reading atlas text files and selecting same, +1, and -1 week templates
        # and locating counterpart labels files
        # Full paths
        declare -a ARRAY_T
        declare -a ARRAY_S
        # File names without paths or extensions
        declare -a ARRAY_T_NAME
        declare -a ARRAY_S_NAME

        let count=0
        # For each template in the template list, compare GA to input case
        while read LINE ; do
            GAtemplate=`echo $LINE | awk -F' ' '{ print $2 }'` # Grab GA of template from TLIST
            casebase=`basename ${image}`
            PathOfT=${FETALREF}/`echo $LINE | awk -F' ' '{ print $1 }'`
            baseT=`basename ${PathOfT}`
            dirT=`dirname ${PathOfT}`

            # We only select atlases within 1 week GA and don't share the same filename as the input case
            if [[ ( ${GAtemplate} == ${GA} || ${GAtemplate} == ${GAm} || ${GAtemplate} == ${GAp} ) && ! ${casebase} == ${baseT} ]] ; then
                ARRAY_T[${count}]=${PathOfT} # Full template path
                tmpName=${ARRAY_T[$count]##*/} # Chop off directory path
                ARRAY_T_NAME[$count]=${tmpName%%.*} # Chop off extension

                # Get the atlas label name and filepath by adding label prefix 
                ARRAY_S_NAME[$count]=`echo ${ARRAY_T_NAME[$count]} | sed -e "s,_atlas,_${lsuffix},"`
                ARRAY_S[$count]=`readlink -f ${dirT}/${ARRAY_S_NAME[$count]}.nii.gz`

                ((count++))
            fi
        done < "${TLIST}"

        # Print out atlas information for this case
        #echo Number of atlas images: ${#ARRAY_T[@]:0:$count}
        #echo Number of atlas labels: ${#ARRAY_S[@]:0:$count}
        echo "  Atlases:"
        printf '%s\n' "${ARRAY_T[@]:0:$count}"
        echo "  Applicable Labels:"
        echo "  NOTE: OKAY if there are none, or if there are blanks"
        echo "        If there are none, segmentation will not process for label atlas '$OutputPrefix'"
        echo "        Listed labels (below) should match the order of listed atlases (above)"
        printf '%s\n' "${ARRAY_S[@]:0:$count}"
        # Check that at least one atlas was found, but it's advisable to have at least 3
        if [[ $count -eq 0 ]] ; then
            echo "Didn't find ANY template images of similar GA. Make sure you have the right template lists selected. Alternatively, if you don't have template images for this GA=$GA, you can try changing the GA of the subject in $inputs to another age for which there are templates."
            echo "Moving on to next case because there are no matches."
            continue
        fi
        echo

        # Multithreading ANTS- create warp files for registration of template grayscale and parcellation to the target image
        # Number of threads maxes out at the user defined number
        let npr=0
        echo "Staring non-rigid registration (ANTS)..."
        tcount=0
        while ( [ $tcount -lt $count ] ) ; do
            while ( [ $npr -lt $NThreads ] ) ; do
                if [ $tcount -lt $count ] ; then
                    # Skip if this reg is already done
                    if [[ ! -e ${outdir}/${name}/template_rT/r${ARRAY_T_NAME[$tcount]}_to_${name}.nii.gz ]] ; then
                            echo "ANTS register ${ARRAY_T_NAME[$tcount]} to ${name}"
                        # Registration command
                        # This produces the "case123Warp.nii.gz", "case123InverseWarp.nii.gz", and "case123Affine.txt" files
                        ANTS 3 -m PR[${image}, ${ARRAY_T[$tcount]},1,2] -o ${outdir}/${name}/template_rT/r${ARRAY_T_NAME[$tcount]}_to_${name}.nii.gz -r Gauss[3,0] --affine-metric-type MI -i 100x100x20 -t SyN[0.4] &
                    else
                        echo "Found transform for ${ARRAY_T_NAME[$tcount]} to ${name}. Skipping..."
                    fi
                    # Increase counts
                    npr=$[ $npr + 1 ]
                    tcount=$[ $tcount + 1 ]
                else
                    npr=$NThreads
                fi
            done
            wait
            npr=0
        done

        # Multithreading Warp for each template image - applying the transformation to the grayscale
        echo "Applying transformations to templates..."
        let npr=0
        tcount=0
        while ( [ ${tcount} -lt ${count} ] ) ; do
            while ( [ ${npr} -lt ${NThreads} ] ) ; do
                if [ ${tcount} -lt ${count} ] ; then
                    if [[ ! -f "$outdir"/"$name"/template_rT/r${ARRAY_T_NAME[$tcount]}_to_${name}.nii.gz ]]; then
                        echo "Applying transform: ${ARRAY_T[$tcount]} to ${name}..."
                        # This produces the warped grayscale e.g. "template123_to_case123.nii.gz"
                        WarpImageMultiTransform 3 ${ARRAY_T[$tcount]} "$outdir"/"$name"/template_rT/r${ARRAY_T_NAME[$tcount]}_to_${name}.nii.gz -R ${image} "$outdir"/"$name"/template_rT/r${ARRAY_T_NAME[$tcount]}_to_${name}\Warp.nii.gz "$outdir"/"$name"/template_rT/r${ARRAY_T_NAME[$tcount]}_to_${name}\Affine.txt &
                    else
                        echo "Atlas has been transformed. Skipping"
                    fi
                    npr=$[ ${npr} + 1 ]
                    tcount=$[ ${tcount} + 1 ]
                else
                    npr=$NThreads
                fi
            done
            wait
            npr=0
        done

        # Multithreading Warp for each template labels
        echo "Applying transformations to template labels"	
        let npr=0
        tcount=0
        while ( [ ${tcount} -lt ${count} ] ) ; do
            while ( [ ${npr} -lt ${NThreads} ] ) ; do
                if [ ${tcount} -lt ${count} ] ; then
                    if [[ ! -f "$outdir"/"$name"/template_rT/r${ARRAY_S_NAME[$tcount]}_to_${name}.nii.gz && -f "${ARRAY_S[$tcount]}" ]]; then
                        echo "Transforming ${ARRAY_S[$tcount]} to ${name}"
                        # This produces the warped parcellation e.g. "template123parc_to_case123.nii.gz"
                        WarpImageMultiTransform 3 ${ARRAY_S[$tcount]} "$outdir"/"$name"/template_rT/r${ARRAY_S_NAME[$tcount]}_to_${name}.nii.gz -R ${image} "$outdir"/"$name"/template_rT/r${ARRAY_T_NAME[$tcount]}_to_"$name"\Warp.nii.gz "$outdir"/"$name"/template_rT/r${ARRAY_T_NAME[$tcount]}_to_"$name"\Affine.txt --use-NN &
                    elif [[ ! -f "${ARRAY_S[$tcount]}" ]] ; then
                        echo "No label file for ${ARRAY_T_NAME[$tcount]}"
                    else
                        echo ""$outdir"/"$name"/template_rT/r${ARRAY_S_NAME[$tcount]}_to_${name}.nii.gz already exists. Skipping..."
                    fi
                    npr=$[ $npr + 1 ]
                    tcount=$[ $tcount + 1 ]
                else
                    npr=$NThreads
                fi
            done
            wait
            npr=0
        done

        # Appending images+labels to list files for segmentation
        # Remove the olds ones
        if [[ -f ""$outdir"/"$name"/log/atlas_for_${OutPre2}.txt" ]]; then rm -v "$outdir"/"$name"/log/atlas_for_${OutPre2}.txt ; fi
        if [[ -f ""$outdir"/"$name"/log/labels_for_${OutPre2}.txt" ]]; then rm -v "$outdir"/"$name"/log/labels_for_${OutPre2}.txt ; fi
        # Write the new ones
        echo "Writing template to text file "$outdir"/"$name"/log/atlas_for_${OutPre2}.txt"
        for ((tcount=0;tcount<$count;++tcount)) ; do
            if [[ -f ""$outdir"/"$name"/template_rT/r${ARRAY_T_NAME[$tcount]}_to_"$name".nii.gz" && -f ""$outdir"/"$name"/template_rT/r${ARRAY_S_NAME[$tcount]}_to_"$name".nii.gz" ]] ; then
                echo ""$outdir"/"$name"/template_rT/r${ARRAY_T_NAME[$tcount]}_to_"$name".nii.gz" >> "$outdir"/"$name"/log/atlas_for_${OutPre2}.txt
                echo ""$outdir"/"$name"/template_rT/r${ARRAY_S_NAME[$tcount]}_to_"$name".nii.gz" >> "$outdir"/"$name"/log/labels_for_${OutPre2}.txt
            fi	
        done
        
        done < $inputs 
        # End of T2 input list loop. Reference label scheme loop still going.
        # We now have all of the needed registrations to run segmentation for this label scheme.

    ## STAPLE multiatlas segmentation ##
    if [[ $segmentation = "ON" ]] ; then
        echo "# # # # # # # # # # # # # # # # # # # # # # # #"
        echo "Starting STAPLE segmentation... # # # # # # # #"
        echo "# # # # # # # # # # # # # # # # # # # # # # # #"
        echo ""

        let ecount=0
        # Start a new T2 input case loop
        while read line; do 
            # Get path, name, and GA
            image=`readlink -f $(echo $line | awk -F' ' '{ print $1 }')`
            echo "time : `date`"
            echo "segmentation scheme: $OutPre2"
            echo "image : ${image}"
            GA=`echo $line | awk -F' ' '{ print $2 }'`
            name=`echo $(basename $image) | awk -F'.' '{ print $1 }'`
            echo "name : $name"
        
            # Create output segmentation directory
            if [[ ! -d ""$outdir"/"$name"/seg" ]]; then mkdir -v ""$outdir"/"$name"/seg"; fi

            # Output segmentation file names
            OutSeg="${outdir}/${name}/seg/${OutPre2}_${name}.nii.gz"
            OutPVC="${outdir}/${name}/PVC/${OutPre2}-pvc_${name}.nii.gz"
    #		corIt2="${outdir}/${name}/PVC/it2-pvc-${OutPre2}_${name}.nii.gz"

            # Use this so we can check number of atlases (can't STAPLE if we only have one atlas, after all)
            labcount=`wc -l "$outdir"/"$name"/log/labels_for_${OutPre2}.txt | cut -d' ' -f1`
            # Check to see we have the script-generated lists of (registered) atlas+labels            
            if [[ ! -e "$outdir"/"$name"/log/labels_for_${OutPre2}.txt || ! -e "$outdir"/"$name"/log/atlas_for_${OutPre2}.txt || $labcount -lt 2 ]] ; then
                echo "  Insufficient transformed atlas images and/or ${OutPre2} parcellations for this case, so STAPLE won't segment ${OutPre2}."
                echo "  If this was unexpected, validate that the input GA matches at least one atlas. Skipping to next input."
                echo ""
                continue
            fi

            # Run segmenation
            if [ ! -e ${OutSeg} ] ; then
                echo "${OutSeg} not found. Processing..."
                $SEG -S "$outdir"/"$name"/log/labels_for_${OutPre2}.txt -T ${image} -I "$outdir"/"$name"/log/atlas_for_${OutPre2}.txt -O ${OutSeg} -x 16 -y 16 -z 16 -X 1 -Y 1 -Z 1 -p ${NThreads}
            else echo "${OutSeg} already exists. Skipping..."
            fi

            # Check conditions to run PVC
            if [[ ${PartialVolumeCorrection} = "ON" ]] ; then
                if [[ ! ${OutPVC} == *"GEPZ"* ]] ; then
                    echo "Not a WM/GM tissue segmentation. Skipping PVC"
                    echo ""
                    continue
                fi
                if [[ ! -e ${OutSeg} ]] ; then
                    echo "  error: ${OutSeg} was not created for some reason, so there's nothing to correct (partial volume correction)."
                    echo ""
                    continue
                fi
                
                # Run PVC
                if [[ ! -e ${OutPVC} ]] ; then
                    echo "Partial volume correction not found. Running..."
                    if [[ ! -d ""$outdir"/"$name"/PVC" ]]; then mkdir -v ""$outdir"/"$name"/PVC"; fi
                    echo "Iteration one"
                    $PVC ${image} ${OutSeg} ${OutPVC} 0.1
                    echo "We're only doing one iteration currently"
    #				echo "Iteration two:"
    #				$PVC ${image} ${corIt1} ${corIt2} 0.5 0.2 0
                    else echo "Partial volume correction ${OutPVC} already complete. Skipping..."
                fi
                    
                # A check to compare output of PVC and confirm that is is decreasing CP volume as intended
                echo "Checking PVC output..."
                BEFORE=`${VOL} ${OutSeg} ${LCP}`
                AFTER=`${VOL} ${OutPVC} ${LCP}`
                declare -a EARRAY
                if (( $(echo "scale=2 ; 100-(${AFTER}/${BEFORE})*100 < 2" | bc -l) )) ; then
                    echo "  FAILURE: Problem detected. Change from SEG to PVC-it1 was less than 2%"
                    echo "PVC didn't have the desired effect of decreasing CP label."
                    echo "Do the CP, SP, and WM labels match what $PVC is expecting?" 
                    EARRAY[${ecount}]=${OutPVC}
                    ((ecount++))
                else echo "  SUCCESS: PVC appears to have had the desired effect (CP change was > 2%)"
                fi
        else echo "Partial volume correction is turned off"
            echo "Open the script in a text editor to turn it on (there is a switch near the top)"
        fi
        echo

        done < $inputs
        # This is the end of the T2 inputs loop for segmentation for this label scheme
    else
        echo ""
        echo "Segmentation turned off - open the script in a text editor to turn it on (there is a switch near the top)"
        echo ""
    fi
done
# End of the entire loop!! Weee! Now to do the next atlas labels- should be faster since registrations are already done    

# # # Post-processing # # #
echo "# # # Post-processing steps begin # # #"
echo

while read line; do
    # Get path, name
    image=`readlink -f $(echo $line | awk -F' ' '{ print $1 }')`
    name=`echo $(basename $image) | awk -F'.' '{ print $1 }'`
    echo "name : $name"


    # CP region multiplication
    echo "# # Image algebra steps # #"
    # Output dir for calculations
    calc="${outdir}/${name}/calc"
    mkdir -pv $calc
    # Check that we have a GEPZ seg and a region seg
    GEPZ="${outdir}/${name}/PVC/MAS-GEPZ-pvc_${name}.nii.gz"
    REGION="${outdir}/${name}/seg/MAS-region_${name}.nii.gz"
    if [[ -f "${GEPZ}" && -f "${REGION}" ]] ; then
        pvcs=`find ${outdir}/${name}/PVC/ -type f -name \*-GEPZ\*pvc_${name}.nii.gz`
        echo "These CP's will be parcellated: ${pvcs}"
        for parc in $pvcs ; do 
            echo "Parcellate GEPZ segs using Region seg"
            parcbase=`basename $parc`
            sub=`echo $parcbase | sed 's,MAS-GEPZ\(.*-pvc\),MAS-GEPZ\1-ParCP,'`
            CPmask="${calc}/CPmask.nii.gz"
            CPnone="${calc}/CPnone.nii.gz"
            CPparc="${calc}/CPparc.nii.gz"
            parcOUT="${calc}/${sub}"
            # Create CP mask from GEPZ
            ${FETALSOFT}/crkit/bin/crlRelabelImages $parc $parc "112 113" "1 1" ${CPmask} 0
            # Create no-CP seg from GEPZ
            ${FETALSOFT}/crkit/bin/crlRelabelImages $parc $parc "112 113" "0 0" ${CPnone}
            # Multiply region by CP
            $MATH ${CPmask} multiply $REGION ${CPparc}
            # Add parcellated CP back to full segmentation
            $MATH ${CPnone} add ${CPparc} ${parcOUT}
            echo "Output: ${parcOUT}"

            # Remove temp files
            rm ${CPmask} ${CPnone} ${CPparc} # ${FinvCP} ${CPnone2} ${rFout}
        done
    else echo "GEPZ or Region segs were not found for image. Skipping."
    fi

    echo

done < $inputs

echo

# Report if there was an error dectected in the partial volume corrections
echo "Report of partial volume success/failure:"
if [[ ${ecount} -gt 0 ]] ; then
	echo "A problem was detected with the output of PVC for the following cases. Check to make sure it is adjusting segmentations as intended"
	printf '%s\n' "${EARRAY[@]:0:$ecount}"
else echo "No PVC issues detected"
fi
