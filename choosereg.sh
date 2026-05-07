#!/bin/bash

#!/bin/bash

show_help () {
cat << EOF
    USAGE: sh ${0##*/} [-c||--compose] -- [BEST IMAGE]
    Incorrect input supplied
    
    Copies BEST IMAGE to atlas_t2final_subjID.nii.gz
    WARNING: deletes all other "FLIRTto" registration attempts

    Optional argument:
    -c||--compose IMAGE     If this is a doubly-registered image, the transforms
                            need to be composed before we save the data. This option
                            runs the tfm compose script ("combineTransforms-t2pipeline.sh")
                            for convenience. The file you supply here would have
                            "_FLIRTto_" in the filename TWICE. Ignore this if this has
                            been done. The output of this is named subjID_FLIRTto_STA.nii.gz.

EOF
}

die() {
    printf '%s\n' "$1" >&2
    exit 1
}

while :; do
    case $1 in
        -h|-\?|--help)
            show_help # help message
            exit
            ;;
        -c|--compose)
            let combine=1
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

function compose {
    scriptdir=`dirname $0`
    if [[ ! -f ${scriptdir}/combineTransforms-t2pipeline.sh ]] ; then
        echo "couldn't find combineTransforms-t2pipeline.sh in your script dir, exiting"
        exit
    fi
    bash ${scriptdir}/combineTransforms-t2pipeline.sh $best 
    }


best="$1"
dir=`dirname $best`
if [[ ! -f $best ]] ; then
    echo "$best doesn't exist"
    exit 1
fi
if [[ $best == *FLIRT*FLIRT* || $combine = 1 ]] ; then
    echo "This transform might need to be composed first. Do you want to compose the two transforms (y/n)"?
    read answer
    if [[ $answer == "y" ]] ; then
        compose
        STA=`find $dir -maxdepth 1 -name \*FLIRTto_STA.nii.gz`
        if [[ ! -f $STA ]] ; then
            echo "This script tried to run the compose script, but it looks like something happened with the output files, which are named FLIRTto_STA.nii.gz. Exiting"
            exit
        else best=$STA
        fi
    else echo "exiting"
        exit
    fi
fi

tmpdir="${dir}/tmp${RANDOM}"
mkdir -v $tmpdir

if [[ ! -d $tmpdir ]] ; then
    echo "couldn't create directory tmp, exiting"
    exit 1
fi

base=`basename $best .nii.gz`
check=`find ${dir} -maxdepth 1 -name ${base}.\*`
checkwc=`echo $check | wc -w`
if [[ $checkwc -lt 2 ]] ; then
    echo "Didn't find at least two files to preserve, exiting (should find final reg and a transform"
    exit
fi

mv -v ${dir}/${base}.* ${tmpdir}/
flirt=${best%%IRTto*}
rm -v ${flirt}*
mv -v ${tmpdir}/${base}.* ${dir}/
rmdir -v ${tmpdir}

full=`readlink -f $best`
regdir=`dirname $full`
recondir=`dirname $regdir`
iddir=`dirname $recondir`
id=`basename $iddir`
cp $best -v ${dir}/atlas_t2final_${id}.nii.gz

echo "Save and name recon output files (placed one level up)"
SHDIR=`dirname $0`
bash ${SHDIR}/t2FilesForDWI.sh ${regdir}
