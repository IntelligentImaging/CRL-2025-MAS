#!/bin/bash

show_help () {
cat << EOF
    USAGE: sh $0 [opt: -id CASEID] -- [T2-space recon] [T2-space mask] [atlas-space recon] [transform T2->Atlas]
    ex: sh $0 mask_r3Drecon_registration.nii atlas_t2final_ID.nii.gz bmnxbSVRTK_ID_FLIRTto_STA30.mat
    Incorrect input supplied

    Optional argument: [-id ID] sets a case ID name for the output files. By default, will take ID from atlas-space recon.
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
        -id)
            ID=$2 # Specify
            shift
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

# Check arguments
if [[ $# -ne 4 ]] ; then
    echo "Incorrect number of arguments"
    show_help
    die
fi
if [[ -f $1 ]] ; then
    T2T2=`readlink -f $1`
else echo "T2-space T2 recon not found, exiting"
    die
fi
if [[ -f $2 ]] ; then
    T2mask=`readlink -f $2`
else echo "Mask not found, exiting"
    die
fi
if [[ -f $3 ]] ; then
    ATLAST2=`readlink -f $3`
else echo "Atlas-space T2 recon not found, exiting"
    die
fi
if [[ -f $4 ]] ; then
    TFM=`readlink -f $4`
else echo "Transform not found, exiting"
    die
fi

# Set Case ID
if [[ ! -n $ID ]] ; then
    base=`basename $ATLAST2`
    ID=`echo ${base%%.*} | sed -e 's,atlas_t2final_,,g'`
fi
echo "ID is $ID"

# Set full paths
SHDIR=`dirname $0`
C3D="${FETALSOFT}/bin/c3d_affine_tool"
FIXMAT="${SHDIR}/changeTFMnameInFileToAffine.py"
REGDIR=`dirname $TFM`
NIIDIR=`dirname $REGDIR`
outTFM="${NIIDIR}/t2-atlas_${ID}.tfm"
outT2T2="${NIIDIR}/t2_t2_${ID}.nii.gz"
outT2mask="${NIIDIR}/t2_mask_${ID}.nii.gz"
outATLAST2="${NIIDIR}/atlas_t2_${ID}.nii.gz"
outATLASmask="${NIIDIR}/atlas_mask_${ID}.nii.gz"

# Next few lines convert the FSL transform to ITK transform, if needed
if ! grep -iq "Insight" $TFM ; then
    echo "Convert transform FSL -> ITK"
    TFMBASE=`basename $TFM .mat`
    TFMITK="${REGDIR}/${TFMBASE}.tfm"
    # Requires Python 3
    if [[ -n `python3 -V` ]] ; then
        # This fixes the arrangement of the numeric values in the transform
        echo "C3D converting transform from .mat to .itk"
        $C3D -ref $ATLAST2 -src $T2T2 $TFM -fsl2ras -oitk $TFMITK
        # This fixes the text in the transform file
        echo "Script to fix header of ITK transform"
        python3 $FIXMAT $TFMITK
    else echo "Python3 not found"
        echo "Required for FSL->ITK transform conversion"
        die
    fi
else
    echo "Transform is already ITK"
    TFMITK="$TFM"
fi

echo "Create inverse transform"
TFMBASE=`basename $TFMITK`
TFMINV="${NIIDIR}/${TFMBASE%%.*}_inv.tfm"
crlAnyTransformToAffineTransform $TFMITK $TFMINV 1 # Invert transform
echo "Resample uncropped recon to atlas space"
crlResampler $T2T2 $TFMITK $ATLAST2 bspline $outATLAST2 # Resample original recon; results in atlas-space recon with surrounding CSF/tissues
echo "Resample mask for uncropped atlas space recon"
crlResampler $T2mask $TFMITK $outATLAST2 nearest $outATLASmask # Resample mask to match image dimensions of outATLAST2

echo "Copy files for naming convention needed in DWI pipeline"
cp $T2T2 -v $outT2T2
cp $T2mask -v $outT2mask
cp $TFMITK -v $outTFM
cp $ATLAST2 -v ${NIIDIR}/${base} # This is the CROPPED/masked atlas-space T2 recon
# copy t2-atlas_CASEID.tfm, atlas*.nii.gz, and t2*.nii.gz to DWI folder for processing (5 files in total)
