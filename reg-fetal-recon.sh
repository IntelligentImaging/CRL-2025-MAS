#!/bin/bash
# Fetal registration using example case brains
shopt -s extglob


show_help () {
cat << EOF
    USAGE: sh ${0##*/} [-h] [-m|--mask mask.nii.gz] [-n|--normalize n] [-t|--target] [-c|--metric] [-ga|--ga GA] [-w|--wide] -- [input]

        Fetal pipeline register to atlas space script

          REQUIRED ARGUMENTS
        [input] Input image which gets registered to atlas space
          OPTIONAL ARGUMENTS
        -h      display help
        -m      supply a binary mask to crop the image (default: no mask)
        -n      run N4 bias correction (after masking) for "n" iterations, usually 3 (default: n=3)
        -t      specify registration target, must be either "ATLAS", "CASES", "EARLY",
                OR specify a single target image for registration.
                "EARLY" should be used for very small brains (~20 weeks and below)
                (default: ATLAS)
        -c      FLIRT registration metric {mutualinfo,corratio,normcorr,normmi,leastsq,labeldiff,bbr} (default is corratio)
        -ga     specify gestational age for atlas matching (default: estimate based on total volume)
        -w      Widens selection of targets to +/- one week GA (default: off)
        -k      Use crkit container for CRL tools

EOF
}

die() {
    printf '%s\n' "$1" >&2
    exit 1
}

# Optional arguments
while :; do
    case $1 in
        -h|-\?|--help)
            show_help # help message
            exit
            ;;
        -m|--mask)
            if [[ "$2" ]] ; then
                MASK=$2
                echo mask is $MASK
                shift
            else
                die 'error: "--mask" requires a mask image'
            fi
            ;;
        -n|--normalize)
            if [[ "$2" ]] ; then
                ITER=$2
                if [[ $ITER -gt 0 ]] ; then
                    echo ITER is $ITER
                    shift
                else die "-n ITER should be a number greater than 0"
                fi
            fi
            ;;
        -t|--target)
            if [[ "$2" ]] ; then
                TARGET=$2
                shift
            else die 'no registration target specified'
            fi
            ;;
        -c|--metric)
            if [[ "$2" ]] ; then
                METRIC=$2
                shift
            else die 'no target specified'
            fi
            ;;
        -ga|--ga)
            if [[ "$2" ]] ; then
                GA=$2
                shift
            else die 'no GA specified'
            fi
            ;;
        -w|--wide)
            WIDE="YES"
            ;;
        -k|--crkit)
            let CRKITCON=1
            ;;
        -?*)
            printf 'warning: unknown option (ignored): %s\n' "$1" >&2
            ;;
        *) # default case, no options
            break
    esac
    shift
done

if [ $# -ne 1 ] ; then
    show_help
    exit
fi

if [ ! -e $1 ] ; then
    echo "error: Could not find $1 ... exiting"
    exit 1
fi

# Required arguments
INPUT=`readlink -f $1`
DIR=`dirname $INPUT`
BASE=`basename $INPUT`
SCRIPT="${DIR}/run-reg.sh"
if [[ ! -n $METRIC ]] ; then METRIC="corratio" ; fi
if [[ ! -n $CRKITCON ]] ; then let CRKITCON=0  ; fi

SHDIR=`dirname $0`
n4="${SHDIR}/n4biascorrect.py"

# THIS FUNCTION IS NOW SKIPPED due to troubles with scoping between terminal environments
# it was not really necessary anyway
# Script could use clean up including removing the function
# registration command to be called later
function register {
            baseT="`basename ${template%%.*}`"
            output=${basebrain}_FLIRTto_${baseT}
            echo "input is $BASE"
            echo "template image is $template"
        	echo "template GA is $tga"
            echo "output files are ${output##*/}"
            echo "reg metric is $METRIC"
            echo "Running FLIRT!"
            flirt -dof 6 -cost $METRIC -in $INPUT -ref $template -omat ${output}.mat -out $output
            }

# If optional mask is supplied, mask input image and set masked image as image which gets registered
CCMASK="${DIR}/mask_r3Drecon_registration.nii.gz"
if [ $MASK ] ; then
    echo "Finalize mask (crlMaskConnectedComponents)"
    maskfilter -largest ${MASK} connect ${CCMASK} -force
    echo Masking image
    MASKED="${DIR}/m${BASE}"

    cmd="crlMaskImage $INPUT $CCMASK $MASKED"
    if [[ $CRKITCON = 1 ]] ; then
        singularity exec docker://arfentul/crkit:latest /bin/bash -c "$cmd"
    else $cmd
    fi

    #fslmaths.fsl $INPUT -mul $CCMASK $MASKED
    INPUT=$MASKED
else
    echo No mask supplied
fi

# If optional N4 bias is supplied, do N4 bias correction n times
if [ $ITER ] ; then
    echo Performing bias correction
    let count=0
    OUT="${DIR}/BIASTEMP.nii.gz"
    CORR="${DIR}/bm${BASE}"
    MAX="${DIR}/tmp_bm${BASE}"
    NEG="${DIR}/tmp_bm${BASE}"
    while [[ $count -lt ${ITER} ]] ; do


        cmd="python3 $n4 -i $INPUT -o $OUT -m $CCMASK"
        if [[ $CRKITCON = 1 ]] ; then
            singularity exec docker://arfentul/crkit:latest /bin/bash -c "$cmd"
        else $cmd
        fi

        INPUT="${OUT}"
        ((count++))
    done
    mv $OUT -v $CORR


    cmd="crlBinaryThreshold $CORR ${DIR}/tmp_noNegMask.nii.gz -10000 0 0 1"
    if [[ $CRKITCON = 1 ]] ; then
        singularity exec docker://arfentul/crkit:latest /bin/bash -c "$cmd"
    else $cmd
    fi

    cmd="crlMaskImage $CORR ${DIR}/tmp_noNegMask.nii.gz ${NEG}"
    if [[ $CRKITCON = 1 ]] ; then
        singularity exec docker://arfentul/crkit:latest /bin/bash -c "$cmd"
    else $cmd
    fi
    
    mrhistmatch scale ${NEG} ~/fetalmri/templates/ref/STA30.nii.gz ${MAX} -force 
    mv -v ${MAX} ${CORR}   

    INPUT=${CORR}
    rm -v ${DIR}/tmp_noNegMask.nii.gz 
fi

# used to name output files
basebrain="${INPUT%%.*}"

# AUTO-DETECT GA if no GA supplied 
if [[ ! -n $GA  && ! -f $TARGET ]] ; then
    # Compare mask volume to each STA mask volume and pick the closest
    echo "Estimating input GA"
    while IFS= read -r line ; do

        # Get atlas GAs and volumes from text file
        atlasGA=`echo $line | cut -d' ' -f1`
        avol=`echo $line | cut -d ' ' -f2`

        # Calculate volume of mask using voxel count multiplied by image spacing 
        maskvoxelcount=`mrstats -q -mask $CCMASK $CCMASK -output count`
        maskimagespace=`mrinfo $CCMASK -spacing | sed -e 's, ,*,g'`
        invol=`echo "$maskvoxelcount * $maskimagespace / 1000" | bc`

        diff=`echo "($avol-$invol)/1" | bc` # Difference btw atlas volume and input image volume
        abs=${diff#-}
        # list all comparison results
        # echo AtlasGA $atlasGA Diff $abs
        # if no comparison values yet, set it using first line
        if [[ -z $pick ]] ; then
            pick="$atlasGA"
            pickvol="$abs"
            # if a line's diff is less than comparison, replace the saved values
        elif [[ $abs -lt $pickvol ]] ; then
            pick="$atlasGA"
            pickvol="$abs"
        fi
    done < "${SHDIR}/GAvols.txt"
    echo "Estimated GA is: $pick"
    GA=$pick
fi

# If a single target was given, use it
if [[ ! -n $TARGET && ${GA} -lt 22 ]] ; then
    TARGET="EARLY"
    echo "Small brain ROI so we will register to early-GA templates"
elif [[ ! -n $TARGET ]] ; then
    TARGET="ATLAS"
    echo "Reg target will be $TARGET"
fi

# Else, we use a list with registration templates
if   [[ $TARGET == "CASES" ]] ; then
	echo "*** Registering $INPUT to same-age cases ***"
    tlist="${SHDIR}/regtemplates/cases.csv"
elif [[ $TARGET == "ATLAS" ]] ; then
	echo "*** Registering $INPUT to same-age STA images ***"
    tlist="${SHDIR}/regtemplates/STA.csv"
elif [[ $TARGET == "EARLY" ]] ; then
    echo "*** Registering $INPUT to EARLY-ga cases ***"
    tlist="${SHDIR}/regtemplates/early.csv"
    GA="21"
elif [[ -f $TARGET ]] ; then
    # ONLY USED IF INDIVIDUAL TARGET FILE IS USED
    echo "Registering to file"
	template=${TARGET}
	tga="NA"
	basebrain="${INPUT%%.*}"
        baseT="`basename ${template%%.*}`"
        output=${basebrain}_FLIRTto_${baseT}
    	# register
	flirt -dof 6 -cost $METRIC -in $INPUT -ref $template -omat ${output}.mat -out $output
	warning="n"
else
    echo "Supplied argument for reference invalid"
    exit
fi

if [[ $TARGET == "ATLAS" || $TARGET == "CASES" || $TARGET == "EARLY" ]] ; then 
	# inspect list of possible registration templates
	while IFS= read -r line ; do 
		# name of template
        template="`echo ${FETALREF}/${line} | cut -d' ' -f1`"
		#template=`readlink -f $(echo ${FETALREF}/${line} | awk -F' ' "{ print $1 }")`
		# GA of template
		tga=`echo $line | awk -F' ' '{ print $2 }'`
		# check if template GA is match for our input GA, if so run command
		# if -w is set it will check for +/-1 GA templates
		if [[ $GA -eq $tga ]] || [[ -n $WIDE && ( ${GA}-${tga} -eq 1 || ${GA}-${tga} -eq -1 ) ]] ; then
		baseT="`basename ${template%%.*}`"
		output=${basebrain}_FLIRTto_${baseT}
	 	# register &
           	flirt -dof 6 -cost $METRIC -in $INPUT -ref $template -omat ${output}.mat -out $output &
			warning="n"
			echo
		fi
	done < ${tlist}
    wait
fi

if [[ ! "$warning" = "n" ]] ; then
	echo "No templates of correct GA were found for ${input}"
fi
