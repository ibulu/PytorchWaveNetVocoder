#!/bin/bash
############################################################
#           SCRIPT TO BUILD SD WAVENET VOCODER             #
############################################################
# Edited by Tomoki Hayashi @ Nagoya University

. ./path.sh
. ./cmd.sh

# USER SETTINGS {{{
#######################################
#           STAGE SETTING             #
#######################################
# {{{
# 0: data preparation step
# 1: feature extraction step
# 2: statistics calculation step
# 3: apply noise shaping step
# 4: training step
# 5: decoding step
# 6: restore noise shaping step
# }}}
stage=0123456

#######################################
#            PATH SETTING             #
#######################################
# {{{
# train: train directory name tag
# eval: eval directory name tag
# tag: experiment name tag (if empty, automatically set)
# }}}
ARCTIC_DB_ROOT=downloads
spk=slt
tag=

#######################################
#          FEATURE SETTING            #
#######################################
# {{{
# shiftms: shift length in msec (default=5)
# fftl: fft length (default=1024)
# min_f0: minimum f0
# max_f0: maximum f0
# highpass_cutoff: highpass filter cutoff frequency (if 0, will not apply)
# mcep_dim: dimension of mel-cepstrum
# mcep_alpha: alpha value of mel-cepstrum
# mag: coefficient of noise shaping (default=0.5)
# n_jobs: number of parallel jobs
# }}}
shiftms=5
fftl=1024
highpass_cutoff=70
fs=16000
mcep_dim=24
mcep_alpha=0.410
mag=0.5
n_jobs=10

#######################################
#          TRAINING SETTING           #
#######################################
# {{{
# lr: learning rate
# iters: number of iterations
# batch_size: batch size
# checkpoints: save model per this number
# use_speaker_code: true or false
# is_noise_shaping: true or false
# }}}
lr=1e-4
iters=200000
batch_size=20000
checkpoints=10000
use_speaker_code=false
is_noise_shaping=true

#######################################
#          DECODING SETTING           #
#######################################
# {{{
# outdir: directory to save decoded wav dir (if not set, will automatically set)
# checkpoint: full path of model to be used to decode (if not set, final model will be used)
# config: model configuration file (if not set, will automatically set)
# feats: list or directory of feature files 
# }}}
outdir= 
checkpoint=
config=
feats=
n_gpus=1

# parse options
. parse_options.sh

# set params
train=tr_${spk}
eval=ev_${spk}
minf0=`cat conf/${spk}.f0 | awk '{print $1}'`
maxf0=`cat conf/${spk}.f0 | awk '{print $2}'`

# stop when error occured
set -e
# }}}


# STAGE 0 {{{
if [ `echo ${stage} | grep 0` ];then
    echo "###########################################################"
    echo "#                 DATA PREPARATION STEP                   #"
    echo "###########################################################"
    if [ ! -e ${ARCTIC_DB_ROOT} ];then
        mkdir -p ${ARCTIC_DB_ROOT}
        cd ${ARCTIC_DB_ROOT}
        for id in bdl slt rms clb jmk ksp awb;do
            wget http://festvox.org/cmu_arctic/cmu_arctic/packed/cmu_us_${id}_arctic-0.95-release.tar.bz2
            tar xf cmu_us_${id}*.tar.bz2
        done
        rm *.tar.bz2
        cd ../
    fi
    [ ! -e data/${train} ] && mkdir -p data/${train}
    find ${ARCTIC_DB_ROOT}/cmu_us_${spk}_arctic/wav -name "*.wav" \
        | sort | head -n 1028 > data/${train}/wav.scp
    [ ! -e data/${eval} ] && mkdir -p data/${eval}
    find ${ARCTIC_DB_ROOT}/cmu_us_${spk}_arctic/wav -name "*.wav" \
       | sort | tail -n 104 > data/${eval}/wav.scp
fi
# }}}


# STAGE 1 {{{
if [ `echo ${stage} | grep 1` ];then
    echo "###########################################################"
    echo "#               FEATURE EXTRACTION STEP                   #"
    echo "###########################################################"
    for set in ${train} ${eval};do
        # training data feature extraction
        ${train_cmd} --num-threads ${n_jobs} exp/feature_extract/featture_extract_${set}.log \
            feature_extract.py \
                --waveforms data/${set}/wav.scp \
                --wavdir wav/${set} \
                --hdf5dir hdf5/${set} \
                --fs ${fs} \
                --shiftms ${shiftms} \
                --minf0 ${minf0} \
                --maxf0 ${maxf0} \
                --mcep_dim ${mcep_dim} \
                --mcep_alpha ${mcep_alpha} \
                --highpass_cutoff ${highpass_cutoff} \
                --fftl ${fftl} \
                --n_jobs ${n_jobs}

        # check the number of feature files
        n_wavs=`cat data/${set}/wav.scp | wc -l`
        n_feats=`find hdf5/${set} -name "*.h5" | wc -l`
        echo "${n_feats}/${n_wavs} files are successfully processed."

        # make scp files
        find wav/${set} -name "*.wav" | sort > data/${set}/wav_filtered.scp
        find hdf5/${set} -name "*.h5" | sort > data/${set}/feats.scp
    done
fi
# }}}


# STAGE 2 {{{
if [ `echo ${stage} | grep 2` ] && ${is_noise_shaping};then
    echo "###########################################################"
    echo "#              CALCULATE STATISTICS STEP                  #"
    echo "###########################################################"
    ${train_cmd} exp/calculate_statistics/calc_stats_${train}.log \
        calc_stats.py \
            --feats data/${train}/feats.scp \
            --stats data/${train}/stats.h5
    echo "statistics are successfully calculated."
fi
# }}}


# STAGE 3 {{{
if [ `echo ${stage} | grep 3` ] && ${is_noise_shaping};then
    echo "###########################################################"
    echo "#                   NOISE SHAPING STEP                    #"
    echo "###########################################################"
    ${train_cmd} --num-threads ${n_jobs} exp/noise_shaping/noise_shaping_apply_${train}.log \
        noise_shaping.py \
            --waveforms data/${train}/wav_filtered.scp \
            --stats data/${train}/stats.h5 \
            --writedir wav_ns/${train} \
            --fs ${fs} \
            --shiftms ${shiftms} \
            --fftl ${fftl} \
            --mcep_dim_start 2 \
            --mcep_dim_end $(( 2 + mcep_dim +1 )) \
            --mcep_alpha ${mcep_alpha} \
            --mag ${mag} \
            --inv true \
            --n_jobs ${n_jobs}

    # check the number of feature files
    n_wavs=`cat data/${train}/wav_filtered.scp | wc -l`
    n_ns=`find wav_ns/${train} -name "*.wav" | wc -l`
    echo "${n_ns}/${n_wavs} files are successfully processed."

    # make scp files
    find wav_ns/${train} -name "*.wav" | sort > data/${train}/wav_ns.scp
fi # }}}


# STAGE 4 {{{
# set variables
if [ ! -n "${tag}" ];then
    expdir=exp/tr_arctic_16k_sd_${spk}_lr${lr}_bs${batch_size}
else
    expdir=exp/${tag}
fi
if [ `echo ${stage} | grep 4` ];then
    echo "###########################################################"
    echo "#               WAVENET TRAINING STEP                     #"
    echo "###########################################################"
    if ${is_noise_shaping};then
        waveforms=data/${train}/wav_ns.scp
    else
        waveforms=data/${train}/wav_filtered.scp
    fi
    ${cuda_cmd} ${expdir}/log/${train}.log \
        train.py \
            --waveforms ${waveforms} \
            --feats data/${train}/feats.scp \
            --stats data/${train}/stats.h5 \
            --expdir ${expdir} \
            --lr ${lr} \
            --iters ${iters} \
            --batch_size ${batch_size} \
            --checkpoints ${checkpoints} \
            --use_speaker_code ${use_speaker_code}
fi
# }}}


# STAGE 5 {{{
if [ `echo ${stage} | grep 5` ];then
    echo "###########################################################"
    echo "#               WAVENET DECODING STEP                     #"
    echo "###########################################################"
    [ ! -n "${outdir}" ] && outdir=${expdir}/wav
    [ ! -n "${checkpoint}" ] && checkpoint=${expdir}/checkpoint-final.pkl
    [ ! -n "${config}" ] && config=${expdir}/model.conf
    [ ! -n "${feats}" ] && feats=data/${eval}/feats.scp
    ${cuda_cmd} --num-threads ${n_jobs} ${expdir}/log/decode.log \
        decode.py \
            --feats ${feats} \
            --stats data/${train}/stats.h5 \
            --outdir ${outdir} \
            --checkpoint ${checkpoint} \
            --config ${expdir}/model.conf \
            --fs ${fs} \
            --n_jobs ${n_jobs} \
            --n_gpus ${n_gpus}
fi
# }}}


# STAGE 6 {{{
if [ `echo ${stage} | grep 6` ] && ${is_noise_shaping};then
    echo "###########################################################"
    echo "#             RESTORE NOISE SHAPING STEP                  #"
    echo "###########################################################"
    [ ! -n "${outdir}" ] && outdir=${expdir}/wav
    find ${outdir} -name "*.wav" | sort > data/${eval}/wav_generated.scp
    ${train_cmd} --num-threads ${n_jobs} exp/noise_shaping/noise_shaping_restore_${eval}.log \
        noise_shaping.py \
            --waveforms data/${eval}/wav_generated.scp \
            --stats data/${train}/stats.h5 \
            --writedir ${outdir}_restored \
            --fs ${fs} \
            --shiftms ${shiftms} \
            --fftl ${fftl} \
            --mcep_dim_start 2 \
            --mcep_dim_end $(( 2 + mcep_dim +1 )) \
            --mcep_alpha ${mcep_alpha} \
            --mag ${mag} \
            --n_jobs ${n_jobs} \
            --inv false
fi
# }}}
