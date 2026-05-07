#!/bin/bash


show_help () {
cat << EOF
    USAGE: sh ${0##*/} [-a] [-s] [-m] [-r] [-a||--all] -- [case svrtk directory]
    Incorrect input supplied

	Must select at least one step to run. Each step requires the output from the previous:
	-a  Mask an arbitrarily chosen input mask to serve as the reconstruction ROI
    -s	SVRTK reconstruction using the images in the input directory
	-m 	T2 recon mask segmentation for the SVRTK recon
	-r	Normalize intensity and register masked recon to atlas
	-o	Output BIDS naming folder
	--all   Do all
 
    You should inspect the input stacks first and remove those you don't need. ~6-9 stacks is plenty.
EOF
}

die() {
    printf '%s\n' "$1" >&2
    exit 1
}

let STEProi=0
let STEPsvr=0
let STEPmask=0
let STEPreg=0
let STEPbids=0

while :; do
    case $1 in
        -h|-\?|--help)
            show_help # help message
            exit
            ;;
        -a)
            let STEProi=1
            ;;
        -s)
            let STEPsvr=1
            ;;
        -m)
            let STEPmask=1
            ;;
        -r)
            let STEPreg=1
            ;;
	-o)
	    let STEPbids=1
	    ;;
        -a|--all)
            let STEProi=1 ; let STEPsvr=1 ; let STEPmask=1 ; let STEPreg=1 ; let STEPbids=1
            ;;
        --) # end of optionals
            shift
            break
            ;;
        -)?*
            printf 'warning: unknown option (ignored: %s\m' "$1" >&2
            ;;
        *) # default case, no optionals
            break
    esac
    shift
done

if [ $# -ne 1 ]; then
    show_help
    exit
fi 

if (( ${STEProi} + ${STEPsvr} + ${STEPmask} + ${STEPreg} + ${STEPbids} == 0 )) ; then die 'Need to specify at least one step to run' ; fi

shdir=`dirname $0`

svrtk=`readlink -f $1`
dir=`dirname $svrtk`
fullid=`basename $dir`

echo
echo "input directory: ${svrtk}"
date

# # # INPUT STACK MASKING # # #
if [[ ${STEProi} = 1 ]] ; then

    echo "# # # STACK MASKING STEP # # #"
    stacks=`find ${svrtk} -maxdepth 1 -name fetus\*z`
    if [[ -n $stacks ]] ; then
        bash ${shdir}/fetal-bet.sh -d -s ${svrtk}
    else
        die "no stacks found in $svrtk"
    fi

fi

# # # SVR RECONSTRUCTION # # #
if [[ ${STEPsvr} = 1 ]] ; then

    echo "# # # SVR RECONSTRUCTION # # #"
    fetuses=`find $1 -maxdepth 1 -type f -name fetus\*.nii.gz`
    svrmask=`find $1 -maxdepth 1 -type f -name mask_\*.nii.gz`

    if [[ ! -n $fetuses || ! -f $svrmask ]] ; then die "t2 stacks (fetus*nii.gz) or mask (mask_*.nii.gz) not found, can't run SVRTK" ; fi

    bash ${shdir}/svrtk-gen.sh ${svrtk} # creates the run script

    if [[ -f ${svrtk}/run-svrtk.sh ]] ; then
        bash ${shdir}/svrtk-exec.sh -s ${svrtk} # -s runs the container with apptainer
    else die "Run script for SVRTK not found"
    fi

    echo "++ SVR recon step done ++"
fi

# # # SVR MASKING and REGISTRATION # # #
if [[ ${STEPmask} = 1 ]] ; then

    echo "# # # SVR MASKING and REGISTRATION # # #"
    svrrecon="${svrtk}/SVRTK_${fullid}.nii.gz"

    if [[ ! -f $svrrecon ]] ; then die "SVRTK reconstruction not found" ; fi
    
    # -n 1 runs one iteration or N4 bias correction
    # -s Tells the script to run brian mask segmentation, DK code, with apptainer
    bash ${shdir}/reg-prep.sh -n 1 -s ${svrrecon} 
    # This step also does intesity normalization

    echo "++ subject-space recon masking done ++"
fi

# # # ATLAS REGISTRATION # # #
if [[ ${STEPreg} = 1 ]] ; then

    echo "# # # ATLAS REGISTRATION # # #"
    subjrecon="${svrtk}/registration/nxbSVRTK_${fullid}.nii.gz"
    subjmask="${svrtk}/registration/mask.nii.gz"

    if [[ ! -f $subjrecon || ! -f $subjmask ]] ; then die "Recon or Mask from step 2 (masking) not found" ; fi

    # -n 2 runs two more iterations of N4 bias correction
    # -m takes the mask from step 2
    bash ${shdir}/reg-fetal-recon.sh -k -n 2 -m ${subjmask} ${subjrecon}
    # This script once again matches intensities to template range.
    # You could add "-w" to Widen the registration template selection to plus and minus one week GA
    # You could add "-t [CASES|EARLY]" to change the registration target to individual subjects or early-GA subjects

    echo "++ atlas registration done ++"
    echo "Now run sh ${shdir}/choosereg.sh on ${svrtk}/registration/bmnxbSVRTK[id]_FLIRTto_STA[ga].nii.gz if you are happy with the result"
fi

# # # OUTPUT FILES # # #
if [[ ${STEPbids} = 1 ]] ; then

	# Assumes the first "FLIRTto" registration is correct
	FLIRTto=`find ${svrtk}/registration -maxdepth 1 -name \*_FLIRTto_\* | head -n1`
	if [[ -f ${FLIRTto} ]] ; then

		bash ${shdir}/choosereg.sh ${FLIRTto}

		# for BIDS naming
		subj=`echo ${fullid} | sed -e 's,s[0-9],,'`
		if [[ ${fullid} == *_s? ]] ; then
		    scan=`echo $fullid | sed -e 's,.*\(s[0-9]\),\1,'`
		else echo couldnt divine scan id from name, defaulting to s1
		    scan="s1"
		fi
		BIDS=${svrtk}/BIDS/${subj}/${scan}
		mkdir -pv ${BIDS}/{anat,xfm}

		cp ${svrtk}/atlas_t2final_${fullid}.nii.gz -vup ${BIDS}/anat/${subj}_${scan}_rec-SVRTK_t2w.nii.gz
		cp ${svrtk}/atlas_mask_${fullid}.nii.gz    -vup ${BIDS}/anat/${subj}_${scan}_rec-SVRTK_desc-mask_t2w.nii.gz
		cp ${svrtk}/t2_t2_${fullid}.nii.gz         -vup ${BIDS}/xfm/${subj}_${scan}_rec-SVRTK_t2w-t2space.nii.gz
		cp ${svrtk}/t2_mask_${fullid}.nii.gz       -vup ${BIDS}/xfm/${subj}_${scan}_rec-SVRTK_desc-mask_t2w-t2space.nii.gz
		cp ${svrtk}/t2-atlas_${fullid}.tfm         -vup ${BIDS}/xfm/${subj}_${scan}_rec-SVRTK_t2w-t2space.tfm
	else
		echo "Didnt find the registered recon named *_FLIRTto_*"
	fi

	echo "Outputs saved to ${svrtk} and ${svrtk}/BIDS/"
fi
