#!/bin/bash


show_help () {
cat << EOF
    USAGE: sh ${0##*/} [input t2 registration dir]
    Incorrect input supplied

    Produces SVRTK pipeline files needed for SK DWI pipeline
EOF
}

if [ $# -ne 1 ]; then
    show_help
    exit
fi 


inpath=`readlink -f $1`
base=`basename $inpath`
if [[ ! $base == "registration" ]] ; then
	inpath=`find ${inpath} -type d -name registration`
	if [[ ! -d ${inpath} ]] ; then
		echo could not find registration directory
		exit
	fi
fi
svrtk=`dirname $inpath`
casedir=`dirname $svrtk`
CASEID=`basename $casedir`

T2=`find $inpath -maxdepth 1 -type f -name nxbSVRTK\*z | head -n 1`
MASK=`find $inpath -maxdepth 1 -name mask_\*_registration\*`
REG=`find $inpath  -maxdepth 1 -iname register\*nii\* -o -iname atlas_t2final\*nii\* | head -n 1`
TFM=`find $inpath -maxdepth 1 -iname \*nx\*txt -o -iname \*nx\*mat -o -iname \*nx\*tfm -o -iname tfm\*nx\*txt -o -iname \*r3D\*mat -o -iname tfm_\*.txt | head -n1`

AT="${svrtk}/atlas_t2_${CASEID}.nii.gz"
ATm="${svrtk}/atlas_mask_${CASEID}.nii.gz"
TM="${svrtk}/t2_t2_${CASEID}.nii.gz"
TMm="${svrtk}/t2_mask_${CASEID}.nii.gz"
outTFM="${svrtk}/t2-atlas_${CASEID}.tfm"
outFINAL="${svrtk}/atlas_t2final_${CASEID}.nii.gz"

if [[ -f ${REG} ]] ; then
    cp ${REG} -vup ${outFINAL}
else echo "Final cropped, atlas space T2 recon wasn't found (not necessary for DWI pipeline)"
fi

if [[ -f $T2 && -f $MASK && -f $REG && -f $TFM ]] ; then
	SHDIR=`dirname $0`
	bash ${SHDIR}/createAtlasT2andMaskFile.sh $T2 $MASK $REG $TFM
else
	echo "One of the needed files not found. Did you run reg-fetal-recon.sh and choosereg.sh ?"
fi

if [[ -f ${AT} && -f ${ATm} && -f ${TM} && -f ${TMm} && -f ${outTFM} && -f ${outFINAL} ]] ; then

    echo "T2 prep done"
else echo "Something went wrong- missing outputs"
fi
echo
