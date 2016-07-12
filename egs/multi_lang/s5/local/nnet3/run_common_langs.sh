#!/bin/bash

. ./cmd.sh
set -e
stage=1
train_stage=-10
generate_alignments=true # false if doing ctc training
speed_perturb=true
pitch_conf=conf/pitch.conf
use_sep_init_layer=true
voicing_conf=

[ ! -f ./conf/common_vars.sh ] && echo 'the file conf/common_vars.sh does not exist!' && exit 1

. conf/common_vars.sh || exit 1;

[ -f local.conf ] && . ./local.conf

. ./utils/parse_options.sh


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
    SWBD)
      langconf=conf/lang/swbd.conf
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

mkdir -p nnet3
# perturbed data preparation
train_set=train
if [ "$speed_perturb" == "true" ]; then
  if [ $stage -le 1 ]; then
    #Although the nnet will be trained by high resolution data, we still have to perturbe the normal data to get the alignment
    # _sp stands for speed-perturbed
    for datadir in train; do
      utils/perturb_data_dir_speed.sh 0.9 data/$L/${datadir} data/$L/temp1
      utils/perturb_data_dir_speed.sh 1.1 data/$L/${datadir} data/$L/temp2
      utils/combine_data.sh data/$L/${datadir}_tmp data/$L/temp1 data/$L/temp2
      utils/validate_data_dir.sh --no-feats data/$L/${datadir}_tmp
      rm -r data/$L/temp1 data/$L/temp2
      
      featdir=plp_perturbed/$L
      steps/make_plp.sh --cmd "$train_cmd" --nj $train_nj data/$L/${datadir}_tmp exp/$L/make_plp/${datadir}_tmp $featdir
      
      steps/compute_cmvn_stats.sh data/$L/${datadir}_tmp exp/$L/make_plp/${datadir}_tmp $featdir || exit 1;
      utils/fix_data_dir.sh data/$L/${datadir}_tmp
      
      utils/copy_data_dir.sh --spk-prefix sp1.0- --utt-prefix sp1.0- data/$L/${datadir} data/$L/temp0
      utils/combine_data.sh data/$L/${datadir}_sp data/$L/${datadir}_tmp data/$L/temp0
      utils/fix_data_dir.sh data/$L/${datadir}_sp
      rm -r data/$L/temp0 data/$L/${datadir}_tmp
    done
  fi
  
  train_set=train_sp
  if [ $stage -le 2 ] && [ "$generate_alignments" == "true" ]; then
    #obtain the alignment of the perturbed data
    steps/align_fmllr.sh \
      --nj 70 --cmd "$train_cmd" \
      --boost-silence $boost_sil \
      data/$L/$train_set data/$L/lang exp/$L/tri5 exp/$L/tri5_ali_sp || exit 1
    touch exp/$L/tri5_ali_sp/.done
  fi
fi

if [ $stage -le 3 ] && [ ! -f data/$L/${train_set}_hires/.done ]; then
  mfccdir=mfcc_hires/$L
  if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d $mfccdir/storage ]; then
    date=$(date +'%m_%d_%H_%M')
    utils/create_split_dir.pl /export/b0{1,2,3,4}/$USER/kaldi-data/egs/$L-$date/s5c/$mfccdir/storage $mfccdir/storage
  fi

  # the 100k_nodup directory is copied seperately, as
  # we want to use exp/tri2_ali_100k_nodup for lda_mllt training
  # the main train directory might be speed_perturbed
  for dataset in $train_set ; do
    utils/copy_data_dir.sh data/$L/$dataset data/$L/${dataset}_hires

    # scale the waveforms, this is useful as we don't use CMVN
    data_dir=data/$L/${dataset}_hires
    cat $data_dir/wav.scp | python -c "
import sys, os, subprocess, re, random
scale_low = 1.0/8
scale_high = 2.0
for line in sys.stdin.readlines():
  if len(line.strip()) == 0:
    continue
  print '{0} sox --vol {1} -t wav - -t wav - |'.format(line.strip(), random.uniform(scale_low, scale_high))
"| sort -k1,1 -u  > $data_dir/wav.scp_scaled || exit 1;
    mv $data_dir/wav.scp_scaled $data_dir/wav.scp

    steps/make_mfcc.sh --nj 70 --mfcc-config conf/mfcc_hires.conf \
        --cmd "$train_cmd" data/$L/${dataset}_hires exp/$L/make_hires/$dataset $mfccdir;
    steps/compute_cmvn_stats.sh data/$L/${dataset}_hires exp/$L/make_hires/${dataset} $mfccdir;

    # Remove the small number of utterances that couldn't be extracted for some
    # reason (e.g. too short; no such file).
    utils/fix_data_dir.sh data/$L/${dataset}_hires;
  done
  touch data/$L/${train_set}_hires/.done
fi

if [ $stage -le 4 ]; then
  if [[ "$use_pitch" == "true" || "$use_entropy" == "true" ]]; then
    echo use_pitch = $use_pitch
    echo use_entropy = $use_entropy
    voicing_conf=conf/voicing_subband_feat.conf
    pitchdir=pitch/$L
    entropydir=entropy/$L
    train_set=${train_set}_hires
    for dataset in $train_set; do
      if $use_pitch; then
        mkdir -p $pitchdir
        if [ ! -f data/$L/${dataset}_pitch/feats.scp ]; then
        utils/copy_data_dir.sh data/$L/$dataset data/$L/${dataset}_pitch
        steps/make_pitch.sh --nj 70 --pitch-config $pitch_conf \
          --cmd "$train_cmd" data/$L/${dataset}_pitch exp/$L/make_pitch/${dataset} $pitchdir;
        fi
        aux_suffix=_pitch
      fi

      if $use_entropy; then
        if [ ! -f data/$L/${dataset}_entropy/feats.scp ]; then
        mkdir -p $entropydir
        utils/copy_data_dir.sh data/$L/$dataset data/$L/${dataset}_entropy
        steps/make_voicing_subband_pitch.sh --nj 70 --voicing-config $voicing_conf \
          --cmd "$train_cmd" data/$L/${dataset}_entropy exp/$L/make_entropy/${dataset} $entropydir;
        fi
        aux_suffix=_entropy
      fi

      if $use_pitch && $use_entropy; then
        steps/append_feats.sh --nj 16 --cmd "$train_cmd" data/$L/${dataset}_pitch \
          data/$L/${dataset}_entropy data/$L/${dataset}_pitch_entropy \
          exp/$L/append_entropy_pitch/${dataset} entropy_pitch/$L
        aux_suffix=_pitch_entropy
      fi

      steps/append_feats.sh --nj 16 --cmd "$train_cmd" data/$L/${dataset} \
        data/$L/${dataset}${aux_suffix} data/$L/${dataset}_mfcc${aux_suffix} \
        exp/$L/append_mfcc${aux_suffix}/${dataset} mfcc${aux_suffix}/$L
   
      steps/compute_cmvn_stats.sh data/$L/${dataset}_mfcc${aux_suffix} exp/$L/make_cmvn_mfcc${aux_suffix}/${x} mfcc${aux_suffix}/$L
    done
  fi
fi

exit 0;
