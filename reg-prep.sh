#!/bin/bash
shopt -s extglob


show_help () {
cat << EOF
    USAGE: sh ${0##*/} [input]
    Incorrect input supplied

	Incorrect argument supplied!
	usage: sh $0 [-n] [-t] [-m] [-s] -- [Best Recon Orientation] 
    Sets up recon registration to atlas space including directory tree and N4 bias correction

        [-n] number of N4 b0-inhomogeneity correction recursive loops (DEFAULT=3)
        [-t] if set, temporary recurions will be preserved (biastemp0, biastemp1, etc)
	[-m] DISABLED-- performs Davood Karimi brain extraction (mask segmentation)
        [-s] use singularity to run container (REQUIRED FOR E2)
	    [-k] use crkit container for CRL tools
EOF
}

die() {
    printf '%s\n' "$1" >&2
    exit 1
}

while :; do
    case $1 in
        -h|-\?|--help)
            show_help
            exit
            ;;
        -n|--N4iterations)
            re='^[0-9]+$'
            if [[ $2 =~ $re ]] ; then
                ITS=$2
                echo "N4 iterations set to $ITS"
                shift
            else
                die 'error: "-n" requires a (whole) number of iterations'
                exit
            fi
            ;;
        -s|--singularity)
            SING="YES"
            ;;
        -t|--temp)
            TEMP="YES"
            ;;
#        -m|--mask)
#            MASK="YES"
#            ;;
        -k|--crkit)
            let CRKITCON=1
            ;;
        -?*)
            printf 'warning: unknown option -- ignored: %s\n' "$1" >&2
            ;;
        *) # default case no options
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

function depend () {
    binary=$1    
    binout=`which $1 2>/dev/null`
    if [[ ! -n $binout ]] ; then
        die "dependency $binary not found - did you mean to switch docker/singularity?"
    else echo dependency $binary found
    fi
}

# N4 binary
SHDIR=`dirname $0`
n4="${SHDIR}/n4biascorrect.py"

# Set naming conventions
RECON=`readlink -f $1`
echo "Try compress"
gzip -v $RECON
RECONDIR=`dirname $RECON`
REGDIR="${RECONDIR}/registration"
BASE=`basename $RECON`
LOG="${REGDIR}/run-reg-prep.sh"
# The chosen orientation is renamed to "best"
if [[ ! $RECON = *"best"* ]] ; then
	BEST=`echo $RECON | sed 's,fetus_,fetus_best_,g'`
else
	BEST=$RECON
fi
mv -v ${RECON} ${BEST}
mkdir -pv ${REGDIR}
# Remove un-chosen r3D's
rm -f ${RECONDIR}/r3DreconOfetus_?.nii.gz
rm -f ${RECONDIR}/r3DreconOfetus_??.nii.gz

# N4 bias correction (iterative loops)
i=0
inN4=$BEST
biascorr="${REGDIR}/b${BASE}"
maxcorr="${REGDIR}/xb${BASE}"
finalcorr="${REGDIR}/nxb${BASE}"
finalcorrBASE=`basename $finalcorr`

echo "N4 bias correction"
while [[ $i -lt $ITS ]] ; do
    biastemp="${REGDIR}/biastemp${i}_${BASE}"
    echo "Step ${i} ..."
    # N4 binary
    cmd="python3 $n4 -i $inN4 -o $biastemp"

	if [[ $CRKITCON=1 ]] ; then
     	   singularity exec docker://arfentul/crkit:latest /bin/bash -c "$cmd"
	else $cmd
	fi

    echo $cmd >> $LOG
    echo "Created $biastemp!"
    # Recurse
    inN4="$biastemp"
    ((i++))
done

# Cleanup N4 temp files
cp -v $inN4 $biascorr
#rm -v $tempmask
if [[ ! $TEMP == "YES" ]] ; then
    rm -v ${REGDIR}/*(biastemp*_${BASE})
fi
echo "N4 bias correction done"

# Intensity correction (N4 changes intensity range)
REF="${FETALREF}/ref/STA30.nii.gz"
echo "Match image intensities to reference image"
cmd="${FETALSOFT}/bin/crlMatchMaxImageIntensity $REF $biascorr $maxcorr"

if [[ $CRKITCON=1 ]] ; then
        singularity exec docker://arfentul/crkit:latest /bin/bash -c "$cmd"
else $cmd
fi

echo $cmd >> $LOG
cmd="${FETALSOFT}/bin/crlNoNegativeValues $maxcorr $finalcorr"

if [[ $CRKITCON=1 ]] ; then
        singularity exec docker://arfentul/crkit:latest /bin/bash -c "$cmd"
else $cmd
fi

echo $cmd >> $LOG

# Open permissions for group to write
find ${REGDIR} -type d -exec chmod -c --preserve-root 775 {} \;

# Davood Karimi Brain Extraction
if [[ $MASK == "YES" || $SING == "YES" ]] ; then
    work="${REGDIR}/BE"
    workpath=`readlink -f $work`
    mkdir -pv $work
    cp ${finalcorr} -v ${work}/
    # Open permission for docker
    chmod 777 $work
    if [[ ! $SING == "YES" ]] ; then 
        depend docker
        echo "Running Davood Karimi brain extraction docker"
        docker run --mount src=$work,target=/src/test_images/,type=bind davoodk/brain_extraction
    else
        depend singularity
        echo "Running brain extraction docker, with singularity"
        singularity run --bind ${workpath}:/src/inputs/ docker://arfentul/maskrecon:0.02
    fi
    seg=`find ${work}/segmentations -type f -name \*segmentation.nii.gz`
    cp ${seg} -v ${REGDIR}/mask.nii.gz
else echo "Brain extraction option not set"
fi
