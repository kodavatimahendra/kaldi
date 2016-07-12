#!/bin/bash
set -e
set -o pipefail


dir=dev10h.pem
kind=
data_only=false
fast_path=true
skip_kws=false
skip_stt=false
skip_scoring=
extra_kws=true
vocab_kws=false
tri5_only=false
use_sep_init_layer=false
use_pitch=true
use_entropy=false
use_ivector=false
use_raw_wave_feats=false
pitch_conf=conf/pitch.conf
wip=0.5
decode_stage=-1
nnet3_dir=nnet3/tdnn_sp
is_rnn=false
use_raw_wave_feats=false
extra_left_context=0
extra_right_context=0
frames_per_chunk=0
wav_input=segmented_wav.scp
aux_suffix=
score_scp=local/score_babel.sh

. conf/common_vars.sh || exit 1;

. utils/parse_options.sh


# bengali: "conf/lang/103-bengali-limitedLP.official.conf"
# assamese: "conf/lang/102-assamese-limitedLP.official.conf"
# cantonese: "conf/lang/101-cantonese-limitedLP.official.conf"
# pashto: "conf/lang/104-pashto-limitedLP.official.conf"
# tagalog: "conf/lang/106-tagalog-limitedLP.official.conf"
# turkish: "conf/lang/105-turkish-limitedLP.official.conf"
# vietnamese: "conf/lang/107-vietnamese-limitedLP.official.conf"
# haitian: "conf/lang/201-haitian-limitedLP.official.conf"
# lao: "conf/lang/203-lao-limitedLP.official.conf"
# zulu: "conf/lang/206-zulu-limitedLP.official.conf"
# tamil: "conf/lang/204-tamil-limitedLP.official.conf"
if [ $# -ne 1 ]; then
  echo "Usage: $(basename $0) --dir <dir-type> <lang>"
  echo " e.g.: $(basename $0) --dir dev2h.pem ASM"
  exit 1
fi

L=$1

case "$L" in
		BNG)
			langconf=conf/lang/103-bengali-limitedLP.official.conf
			;;
		ASM)			
			langconf=conf/lang/102-assamese-limitedLP.official.conf
			;;
		CNT)
			langconf=conf/lang/101-cantonese-limitedLP.official.conf
			;;
		PSH)
			langconf=conf/lang/104-pashto-limitedLP.official.conf
			;;
		TGL)
			langconf=conf/lang/106-tagalog-limitedLP.official.conf
			;;
		TUR)
			langconf=conf/lang/105-turkish-limitedLP.official.conf	
			;;
		VTN)
			langconf=conf/lang/107-vietnamese-limitedLP.official.conf
			;;
		HAI)
			langconf=conf/lang/201-haitian-limitedLP.official.conf
			;;
		LAO)
			langconf=conf/lang/203-lao-limitedLP.official.conf
			;;
		ZUL)
			langconf=conf/lang/206-zulu-limitedLP.official.conf	
			;;
		TAM)
			langconf=conf/lang/204-tamil-limitedLP.official.conf	
			;;
		*)
			echo "Unknown language code $L." && exit 1
esac

mkdir -p langconf/$L
rm -rf langconf/$L/*
cp $langconf langconf/$L/lang.conf
langconf=langconf/$L/lang.conf

[ ! -f $langconf ] && echo 'Language configuration does not exist! Use the configurations in conf/lang/* as a startup' && exit 1
. $langconf || exit 1;
[ -f local.conf ] && . local.conf;
echo using "Language = $L, config = $langconf"

mfcc=mfcc/$L
plp=plp/$L
data=data/$L

ivector_suffix=
if ! $use_sep_init_layer; then
  ivector_suffix=_gb
fi
echo ivector_suffix = $ivector_suffix
#This seems to be the only functioning way how to ensure the comple
#set of scripts will exit when sourcing several of them together
#Otherwise, the CTRL-C just terminates the deepest sourced script ?
# Let shell functions inherit ERR trap.  Same as `set -E'.
set -o errtrace
trap "echo Exited!; exit;" SIGINT SIGTERM

# Set proxy search parameters for the extended lexicon case.
if [ -f $data/.extlex ]; then
  proxy_phone_beam=$extlex_proxy_phone_beam
  proxy_phone_nbest=$extlex_proxy_phone_nbest
  proxy_beam=$extlex_proxy_beam
  proxy_nbest=$extlex_proxy_nbest
fi

dataset_segments=${dir##*.}
dataset_dir=$data/$dir
dataset_id=$dir
dataset_type=${dir%%.*}
#By default, we want the script to accept how the dataset should be handled,
#i.e. of  what kind is the dataset
if [ -z ${kind} ] ; then
  if [ "$dataset_type" == "dev2h" ] || [ "$dataset_type" == "dev10h" ]; then
    dataset_kind=supervised
  else
    dataset_kind=unsupervised
  fi
else
  dataset_kind=$kind
fi

if [ -z $dataset_segments ]; then
  echo "You have to specify the segmentation type as well"
  echo "If you are trying to decode the PEM segmentation dir"
  echo "such as data/dev10h, specify dev10h.pem"
  echo "The valid segmentations types are:"
  echo "\tpem   #PEM segmentation"
  echo "\tuem   #UEM segmentation in the CMU database format"
  echo "\tseg   #UEM segmentation (kaldi-native)"
fi

if [ -z "${skip_scoring}" ] ; then
  if [ "$dataset_kind" == "unsupervised" ]; then
    skip_scoring=true
  else
    skip_scoring=false
  fi
fi

#The $dataset_type value will be the dataset name without any extrension
eval my_data_dir=( "\${${dataset_type}_data_dir[@]}" )
eval my_data_list=( "\${${dataset_type}_data_list[@]}" )
if [ -z $my_data_dir ] || [ -z $my_data_list ] ; then
  echo "Error: The dir you specified ($dataset_id) does not have existing config";
  exit 1
fi

eval my_stm_file=\$${dataset_type}_stm_file
eval my_ecf_file=\$${dataset_type}_ecf_file
eval my_rttm_file=\$${dataset_type}_rttm_file
eval my_nj=\$${dataset_type}_nj  #for shadow, this will be re-set when appropriate

if [ -z "$my_nj" ]; then
  echo >&2 "You didn't specify the number of jobs -- variable \"${dataset_type}_nj\" not defined."
  exit 1
fi

my_subset_ecf=false
eval ind=\${${dataset_type}_subset_ecf+x}
if [ "$ind" == "x" ] ; then
  eval my_subset_ecf=\$${dataset_type}_subset_ecf
fi

declare -A my_kwlists=()
eval my_kwlist_keys="\${!${dataset_type}_kwlists[@]}"
for key in $my_kwlist_keys  # make sure you include the quotes there
do
  eval my_kwlist_val="\${${dataset_type}_kwlists[$key]}"
  my_kwlists["$key"]="${my_kwlist_val}"
done

#Just a minor safety precaution to prevent using incorrect settings
#The dataset_* variables should be used.
set -e
set -o pipefail
set -u
unset dir
unset kind

function make_plp {
  target=$1
  logdir=$2
  output=$3
  #if $use_pitch; then
  #  steps/make_plp_pitch.sh --cmd "$decode_cmd" --nj $my_nj $target $logdir $output
  #else
  steps/make_plp.sh --cmd "$decode_cmd" --nj $my_nj $target $logdir $output
  #fi
  utils/fix_data_dir.sh $target
  steps/compute_cmvn_stats.sh $target $logdir $output
  utils/fix_data_dir.sh $target
}

function check_variables_are_set {
  for variable in $mandatory_variables ; do
    if ! declare -p $variable ; then
      echo "Mandatory variable ${variable/my/$dataset_type} is not set! "
      echo "You should probably set the variable in the config file "
      exit 1
    else
      declare -p $variable
    fi
  done

  if [ ! -z ${optional_variables+x} ] ; then
    for variable in $optional_variables ; do
      eval my_variable=\$${variable}
      echo "$variable=$my_variable"
    done
  fi
}

if [ ! -f $data/raw_${dataset_type}_data/.done ]; then
  echo ---------------------------------------------------------------------
  echo "Subsetting the ${dataset_type} set"
  echo ---------------------------------------------------------------------

  l1=${#my_data_dir[*]}
  l2=${#my_data_list[*]}
  if [ "$l1" -ne "$l2" ]; then
    echo "Error, the number of source files lists is not the same as the number of source dirs!"
    exit 1
  fi

  resource_string=""
  if [ "$dataset_kind" == "unsupervised" ]; then
    resource_string+=" --ignore-missing-txt true"
  fi

  for i in `seq 0 $(($l1 - 1))`; do
    resource_string+=" ${my_data_dir[$i]} "
    resource_string+=" ${my_data_list[$i]} "
  done
  local/make_corpus_subset.sh $resource_string ./$data/raw_${dataset_type}_data
  touch $data/raw_${dataset_type}_data/.done
fi
my_data_dir=`readlink -f ./$data/raw_${dataset_type}_data`
[ -f $my_data_dir/filelist.list ] && my_data_list=$my_data_dir/filelist.list
nj_max=`cat $my_data_list | wc -l` || nj_max=`ls $my_data_dir/audio | wc -l`

if [ "$nj_max" -lt "$my_nj" ] ; then
  echo "Number of jobs ($my_nj) is too big!"
  echo "The maximum reasonable number of jobs is $nj_max"
  my_nj=$nj_max
fi

#####################################################################
#
# Audio data directory preparation
#
#####################################################################
echo ---------------------------------------------------------------------
echo "Preparing ${dataset_kind} data files in ${dataset_dir} on" `date`
echo ---------------------------------------------------------------------
if [ ! -f  $dataset_dir/.done ] ; then
  if [ "$dataset_kind" == "supervised" ]; then
    if [ "$dataset_segments" == "seg" ]; then
      . ./local/datasets/supervised_seg.sh || exit 1
    elif [ "$dataset_segments" == "uem" ]; then
      . ./local/datasets/supervised_uem.sh || exit 1
    elif [ "$dataset_segments" == "pem" ]; then
      . ./local/datasets/supervised_pem.sh || exit 1
    else
      echo "Unknown type of the dataset: \"$dataset_segments\"!";
      echo "Valid dataset types are: seg, uem, pem";
      exit 1
    fi
  elif [ "$dataset_kind" == "unsupervised" ] ; then
    if [ "$dataset_segments" == "seg" ] ; then
      . ./local/datasets/unsupervised_seg.sh
    elif [ "$dataset_segments" == "uem" ] ; then
      . ./local/datasets/unsupervised_uem.sh
    elif [ "$dataset_segments" == "pem" ] ; then
      ##This combination does not really makes sense,
      ##Because the PEM is that we get the segmentation
      ##and because of the format of the segment files
      ##the transcript as well
      echo "ERROR: $dataset_segments combined with $dataset_type"
      echo "does not really make any sense!"
      exit 1
      #. ./local/datasets/unsupervised_pem.sh
    else
      echo "Unknown type of the dataset: \"$dataset_segments\"!";
      echo "Valid dataset types are: seg, uem, pem";
      exit 1
    fi
  else
    echo "Unknown kind of the dataset: \"$dataset_kind\"!";
    echo "Valid dataset kinds are: supervised, unsupervised, shadow";
    exit 1
  fi

  if [ ! -f ${dataset_dir}/.plp.done ]; then
    echo ---------------------------------------------------------------------
    echo "Preparing ${dataset_kind} parametrization files in ${dataset_dir} on" `date`
    echo ---------------------------------------------------------------------
    make_plp ${dataset_dir} exp/$L/make_plp/${dataset_id} plp/$L
    touch ${dataset_dir}/.plp.done
  fi

  dataset=$(basename $dataset_dir)
  echo use_ivector = $use_ivector
  if $use_ivector && [ ! -f exp/$L/nnet3/ivectors_${dataset}${ivector_suffix}/.ivector.done ];then
    extractor=exp/$L/nnet3/extractor
    if ! $use_sep_init_layer; then
      extractor=exp/multi/nnet3/extractor
    fi
    steps/online/nnet2/extract_ivectors_online.sh --cmd "$train_cmd" --nj $my_nj \
      ${dataset_dir}_hires $extractor exp/$L/nnet3/ivectors_${dataset}${ivector_suffix} || exit 1;
    touch exp/$L/nnet3/ivectors_${dataset}${ivector_suffix}/.ivector.done 
  fi
  
  if [ ! -f ${dataset_dir}_hires/.mfcc.done ]; then
    dataset=$(basename $dataset_dir)
    echo ---------------------------------------------------------------------
    echo "Preparing ${dataset_kind} MFCC features in  ${dataset_dir}_hires and corresponding iVectors in exp/$L/nnet3/ivectors_${dataset}${ivector_suffix} on" `date`
    echo ---------------------------------------------------------------------
    if [ ! -d ${dataset_dir}_hires ]; then
      utils/copy_data_dir.sh $data/$dataset $data/${dataset}_hires
    fi

    mfccdir=mfcc_hires/$L
    steps/make_mfcc.sh --nj $my_nj --mfcc-config conf/mfcc_hires.conf \
        --cmd "$train_cmd" ${dataset_dir}_hires exp/$L/make_hires/$dataset $mfccdir;
    steps/compute_cmvn_stats.sh ${dataset_dir}_hires exp/$L/make_hires/${dataset} $mfccdir;
    utils/fix_data_dir.sh ${dataset_dir}_hires;
    touch ${dataset_dir}_hires/.mfcc.done
    
  
    touch ${dataset_dir}_hires/.done
  fi
  touch $dataset_dir/.done
fi

echo use_pitch = $use_pitch and use_entropy = $use_entropy 
if true; then
  if [[ "$use_pitch" == "true" || "$use_entropy" == "true" ]]; then
    dataset=$(basename $dataset_dir)
    echo use_pitch = $use_pitch
    echo use_entropy = $use_entropy
    pitchdir=pitch/$L
    entropydir=entropy/$L
    if $use_pitch; then
      if [ ! -f ${dataset_dir}_pitch/.done ]; then
        utils/copy_data_dir.sh ${dataset_dir} ${dataset_dir}_pitch
        steps/make_pitch.sh --nj 70 --pitch-config $pitch_conf \
          --cmd "$train_cmd" ${dataset_dir}_pitch exp/$L/make_pitch/${dataset} $pitchdir;
        touch ${dataset_dir}_pitch/.done
      fi
      aux_suffix=${aux_suffix}_pitch
    fi

    if $use_entropy; then
      if [ ! -f ${dataset_dir}_entropy/.done ]; then
        utils/copy_data_dir.sh ${dataset_dir} ${dataset_dir}_entropy
        steps/make_voicing_subband_pitch.sh --nj 70 --voicing-config $voicing_conf \
          --cmd "$train_cmd" ${dataset_dir}_entropy exp/$L/make_entropy/${dataset} $entropydir;
        touch ${dataset_dir}_entropy/.done
      fi
      aux_suffix=${aux_suffix}_entropy
    fi

    if $use_pitch && $use_entropy; then
      if [ ! -f ${dataset_dir}_pitch_entropy/.done ]; then
        steps/append_feats.sh --nj 16 --cmd "$train_cmd" ${dataset_dir}_pitch \
          ${dataset_dir}_entropy ${dataset_dir}_pitch_entropy \
          exp/$L/append_entropy_pitch/${dataset} entropy_pitch/$L
        touch ${dataset_dir}_pitch_entropy/.done
      fi
      aux_suffix=${aux_suffix}_pitch_entropy
    fi
    
    if [ ! -f ${dataset_dir}_hires_mfcc${aux_suffix}/.done ]; then
      steps/append_feats.sh --nj 16 --cmd "$train_cmd" ${dataset_dir}_hires \
        ${dataset_dir}${aux_suffix} ${dataset_dir}_hires_mfcc${aux_suffix} \
        exp/$L/append_mfcc${aux_suffix}/${dataset} mfcc_hires${aux_suffix}/$L
   
      steps/compute_cmvn_stats.sh ${dataset_dir}_hires_mfcc${aux_suffix} \
        exp/$L/make_cmvn_mfcc${aux_suffix}/${dataset} mfcc_hires${aux_suffix}/$L

      touch ${dataset_dir}_hires_mfcc${aux_suffix}/.done
    fi
  fi
fi

#####################################################################
#
# KWS data directory preparation
#
#####################################################################
echo ---------------------------------------------------------------------
echo "Preparing kws data files in ${dataset_dir} on" `date`
echo ---------------------------------------------------------------------
lang=$data/lang
if false; then #100
if ! $skip_kws ; then
  if  $extra_kws ; then
    L1_lex=data/local/lexiconp.txt
    . ./local/datasets/extra_kws.sh || exit 1
  fi
  if  $vocab_kws ; then
    . ./local/datasets/vocab_kws.sh || exit 1
  fi
fi
fi #100
if $data_only ; then
  echo "Exiting, as data-only was requested..."
  exit 0;
fi

####################################################################
## FMLLR decoding
##
####################################################################
decode=exp/$L/tri5/decode_${dataset_id}
if [ ! -f exp/$L/tri5/graph/HCLG.fst ];then
  utils/mkgraph.sh \
    data/$L/lang exp/$L/tri5 exp/$L/tri5/graph |tee exp/$L/tri5/mkgraph.log
fi
if false; then #100
if [ ! -f ${decode}/.done ]; then
  echo ---------------------------------------------------------------------
  echo "Spawning decoding with SAT models  on" `date`
  echo ---------------------------------------------------------------------
  utils/mkgraph.sh \
    data/$L/lang exp/$L/tri5 exp/$L/tri5/graph |tee exp/$L/tri5/mkgraph.log

  mkdir -p $decode
  #By default, we do not care about the lattices for this step -- we just want the transforms
  #Therefore, we will reduce the beam sizes, to reduce the decoding times
  steps/decode_fmllr_extra.sh --skip-scoring true --beam 10 --lattice-beam 4\
    --nj $my_nj --cmd "$decode_cmd" "${decode_extra_opts[@]}"\
    exp/$L/tri5/graph ${dataset_dir} ${decode} |tee ${decode}/decode.log
  touch ${decode}/.done
fi

fi #100

if $tri5_only; then
  echo "--tri5-only is true. So exiting."
  exit 0
fi

####################################################################
##
## nnet3 model decoding
##
####################################################################

if [ -f $nnet3_dir/final.mdl ]; then
  echo "nnet3 decoding"
  decode=$nnet3_dir/decode_${dataset_id}
  rnn_opts=
  decode_script=steps/nnet3/decode.sh
  raw_configs=
  aux_suffix=
  if $use_raw_wave_feats; then
    aux_suffix=${aux_suffix}_raw
    decode_script=steps/nnet3/decode_raw.sh
    raw_configs="--wav-input $wav_input"
  fi
  
  # suffix for using other features such as pitch or entropy
  if [[ "$use_pitch" == "true" || "$use_entropy" == "true" ]]; then
    aux_suffix=${aux_suffix}_mfcc
    if $use_pitch; then
      aux_suffix=${aux_suffix}_pitch
    fi
    if $use_entropy;then
      aux_suffix=${aux_suffix}_entropy
    fi
  fi
  ivector_opts=
  if $use_ivector; then
    ivector_opts="--online-ivector-dir exp/$L/nnet3/ivectors_${dataset_id}${ivector_suffix}"
  fi
  if [ "$is_rnn" == "true" ]; then
    rnn_opts=" --extra-left-context $extra_left_context --extra-right-context $extra_right_context  --frames-per-chunk $frames_per_chunk " 
    decode_script=steps/nnet3/lstm/decode.sh
    if $use_raw_wave_feats; then
      echo decode raw waveform setup
      decode_script=steps/nnet3/lstm/decode_raw.sh
      raw_configs="--wav-input $wav_input"
    fi
  fi
  score_scp="--score-scp $score_scp"
  if [ ! -f $decode/.done ]; then
    mkdir -p $decode

    $decode_script --nj $my_nj --cmd "$decode_cmd" $rnn_opts $raw_configs --stage $decode_stage \
          --beam $dnn_beam --lattice-beam $dnn_lat_beam \
          --skip-scoring false  $ivector_opts $score_scp \
          exp/$L/tri5/graph ${dataset_dir}_hires${aux_suffix} $decode | tee $decode/decode.log
    
    touch $decode/.done
  fi
fi



####################################################################
##
## DNN (nextgen DNN) decoding
##
####################################################################
if [ -f exp/tri6a_nnet/.done ]; then
  decode=exp/tri6a_nnet/decode_${dataset_id}
  if [ ! -f $decode/.done ]; then
    mkdir -p $decode
    steps/nnet2/decode.sh \
      --minimize $minimize --cmd "$decode_cmd" --nj $my_nj \
      --beam $dnn_beam --lattice-beam $dnn_lat_beam \
      --skip-scoring true "${decode_extra_opts[@]}" \
      --transform-dir exp/tri5/decode_${dataset_id} \
      exp/tri5/graph ${dataset_dir} $decode | tee $decode/decode.log

    touch $decode/.done
  fi

  local/run_kws_stt_task.sh --cer $cer --max-states $max_states \
    --skip-scoring $skip_scoring --extra-kws $extra_kws --wip $wip \
    --cmd "$decode_cmd" --skip-kws $skip_kws --skip-stt $skip_stt  \
    "${lmwt_dnn_extra_opts[@]}" \
    ${dataset_dir} data/lang $decode
fi


####################################################################
##
## DNN (ensemble) decoding
##
####################################################################
if [ -f exp/tri6b_nnet/.done ]; then
  decode=exp/tri6b_nnet/decode_${dataset_id}
  if [ ! -f $decode/.done ]; then
    mkdir -p $decode
    steps/nnet2/decode.sh \
      --minimize $minimize --cmd "$decode_cmd" --nj $my_nj \
      --beam $dnn_beam --lattice-beam $dnn_lat_beam \
      --skip-scoring true "${decode_extra_opts[@]}" \
      --transform-dir exp/tri5/decode_${dataset_id} \
      exp/tri5/graph ${dataset_dir} $decode | tee $decode/decode.log

    touch $decode/.done
  fi

  local/run_kws_stt_task.sh --cer $cer --max-states $max_states \
    --skip-scoring $skip_scoring --extra-kws $extra_kws --wip $wip \
    --cmd "$decode_cmd" --skip-kws $skip_kws --skip-stt $skip_stt  \
    "${lmwt_dnn_extra_opts[@]}" \
    ${dataset_dir} data/lang $decode
fi
####################################################################
##
## DNN_MPE decoding
##
####################################################################
if [ -f exp/tri6_nnet_mpe/.done ]; then
  for epoch in 1 2 3 4; do
    decode=exp/tri6_nnet_mpe/decode_${dataset_id}_epoch$epoch
    if [ ! -f $decode/.done ]; then
      mkdir -p $decode
      steps/nnet2/decode.sh --minimize $minimize \
        --cmd "$decode_cmd" --nj $my_nj --iter epoch$epoch \
        --beam $dnn_beam --lattice-beam $dnn_lat_beam \
        --skip-scoring true "${decode_extra_opts[@]}" \
        --transform-dir exp/tri5/decode_${dataset_id} \
        exp/tri5/graph ${dataset_dir} $decode | tee $decode/decode.log

      touch $decode/.done
    fi

    local/run_kws_stt_task.sh --cer $cer --max-states $max_states \
      --skip-scoring $skip_scoring --extra-kws $extra_kws --wip $wip \
      --cmd "$decode_cmd" --skip-kws $skip_kws --skip-stt $skip_stt  \
      "${lmwt_dnn_extra_opts[@]}" \
      ${dataset_dir} data/lang $decode
  done
fi

####################################################################
##
## DNN semi-supervised training decoding
##
####################################################################
for dnn in tri6_nnet_semi_supervised tri6_nnet_semi_supervised2 \
          tri6_nnet_supervised_tuning tri6_nnet_supervised_tuning2 ; do
  if [ -f exp/$dnn/.done ]; then
    decode=exp/$dnn/decode_${dataset_id}
    if [ ! -f $decode/.done ]; then
      mkdir -p $decode
      steps/nnet2/decode.sh \
        --minimize $minimize --cmd "$decode_cmd" --nj $my_nj \
        --beam $dnn_beam --lattice-beam $dnn_lat_beam \
        --skip-scoring true "${decode_extra_opts[@]}" \
        --transform-dir exp/tri5/decode_${dataset_id} \
        exp/tri5/graph ${dataset_dir} $decode | tee $decode/decode.log

      touch $decode/.done
    fi

    local/run_kws_stt_task.sh --cer $cer --max-states $max_states \
      --skip-scoring $skip_scoring --extra-kws $extra_kws --wip $wip \
      --cmd "$decode_cmd" --skip-kws $skip_kws --skip-stt $skip_stt  \
      "${lmwt_dnn_extra_opts[@]}" \
      ${dataset_dir} data/lang $decode
  fi
done
echo "Everything looking good...."
exit 0
