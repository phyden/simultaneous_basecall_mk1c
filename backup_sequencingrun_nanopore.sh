#!/bin/bash

### SETTINGS ###
Location=yourlocation
Hostname=$(hostname)
BackUpSubdir=$Hostname
BackupHost=yourbackuphost

### BASECALLING PARAMETERS ###
BCBarcodeKit=SQK-RBK110-96
BCConfigPath=/opt/ont/guppy/data/dna_r9.4.1_450bps_fast.cfg
BCChunkSize=30 #number of fast5 files to be processed per basecall_client call

### GLOBAL PARAMETERS###
# ATTN! Do not change parameters here unless you know what you're doing #
# pidFile indicating that process is still running (avoid parallel calls of script)
pidFile=/data/backup_running.pid

# MountPoint as specified in /etc/fstab. needs to be mounted/unmounted if reconnection function should work
MountPoint=/mnt/sequencer

# Backup directory structure - might be created at runtime if user has the privileges
BackupBase=$MountPoint/Backup_Nanopore/Backup
BackupDir=$BackupBase/$(date +%Y)/$Location/$BackUpSubdir

# Location/names of the log files
BackupLogFile=$BackupBase"/copy_log_"$Location"_"$Hostname".txt"
LocalLog=/home/minit/File_transfer_log.txt

# Nanopore specific output directory to look for runs
OutputBase=/data

### FUNCTIONS ###

# Simple logging function that adds datetime to message
# writes to both local and remote logfile
logit()
{
    msg=$(date '+%d.%m.%Y %H:%M:%S')": "$@
    echo $msg >> $LocalLog
    echo $msg >> $BackupLogFile
    echo $msg
}

# Creates MD5-sum hashes to later confirm successful copy.
# file "md5_sums.txt" is created in local run dir
# should be called prior to copying
createhash()
{
    rundir=$1
    for fastqfile in $(find $rundir -name "*.fastq.gz" -print | grep "fastq_pass"); do
        hash=$(md5sum $fastqfile | cut -f5 -d" ")
        echo "$fastqfile;$hash"
    done > $rundir/md5_sums.txt
}

# Check if directory is already in backup and backup was successful
# file "md5sums_failed" is generated by serverpipeline if hashes differ: indicates incomplete transfer
BackupComplete()
{
    rundir=$1
    backup_target_dir=$BackupDir/$rundir
    if [ -d $backup_target_dir ]; then
        if [ -f $backup_target_dir/md5sums_failed ]; then
            logit "Backup found but incomplete or damaged files found"
            rm $backup_target_dir/md5sums_failed
            rm $backup_target_dir/CopyComplete.out
            return 0
        else
            return 1
        fi
    else
        return 1
    fi
}


# Uses copy programs transfering relevant output files to $BackupHost
BackupRunDir()
{
    OutputDir=$1
    subDir=$2
    # Create MD5-sums for FastqFiles # we will not perform this for nanopore atm
    #createhash $OutputDir
    backup_target_dir=$BackupDir/$subDir
    run_hash=$(basename $subDir | cut -f1 -d"_")
    mkdir -p $backup_target_dir
    logit "Contatenating readfiles in $subDir"
    # concatenate readfiles, to avoid large number of small files being processed
    for barcode in $(ls $OutputDir/fastq_pass); do
        mkdir -p $OutputDir/fastq_concat/$barcode
        ls $OutputDir/fastq_pass/$barcode | xargs --no-run-if-empty -I {} zcat $OutputDir/fastq_pass/$barcode/{} | gzip -c - > $OutputDir/fastq_concat/$barcode/$run_hash"_"$barcode".fastq.gz"
    done
    # rename output, to backup only the large files
    mv $OutputDir/fastq_pass $OutputDir/fastq_pass_smallfiles
    mv $OutputDir/fastq_concat $OutputDir/fastq_pass

    # copy with rsync, limit bandwith to 100Mbit
    # exclude unclassified, fast5, failed, sequencing_summary file
    logit "Copy $OutputDir to $backup_target_dir started"
    rsync -a --bwlimit=100000 --exclude "fast5*" --exclude "*_fail" --exclude "fastq_pass_smallfiles" --exclude "unclassified" --exclude "sequencing_summary*" $OutputDir/ $backup_target_dir
    logit "Copy $OutputDir to $backup_target_dir ended"

    # create a flag file for the processing server to know that transfer is completed
    date "+%d.%m.%Y %H:%M" > $backup_target_dir/CopyComplete.out
}

# Function to check network connection
NetworkUnavailable()
{
    received=$(ping -c 4 $BackupHost | grep -o "[0-9] received" | cut -f1 -d " ")
    if [ $received -gt 0 ]; then
        return 1
    else
        return 0
    fi
}

# Re-connect to share
# Note: /etc/fstab needs to contain a drive mountable to $MountPoint
NetworkNotConnected()
{
    md5sum $BackupLogFile > /dev/null
    if [ $? -gt 0 ]; then
        logit "Try re-connecting remote storage server $BackupHost"
        umount $MountPoint
        mount $MountPoint
        return 0
    else
        return 1
    fi
}

# Check if incomplete Basecalling files are present
# continue basecalling chunkwise
CompleteBasecalling()
{
    rundir=$1
    for input_dir in $rundir/fast5{,_skip}; do
        if [ -d $input_dir ]; then
            cd $input_dir

            # loop over fast5 inputfiles and perform chunkwise basecalling
            # calls guppy_basecall_client with specified parameters until there are no fast5 files left in /fast5 or /fast5_skip.
            # fast5 basecall output is disabled
            while [ $(ls $input_dir | grep -c ".fast5$") -gt 0 ]; do
                tmpdir=$(mktemp -d -p $input_dir)
                mkdir -p $tmpdir/fast5
                ls | grep ".fast5$" | head -n $BCChunkSize | xargs --no-run-if-empty -I {} mv {} $tmpdir/fast5
                if [ $(ls $tmpdir/fast5 | wc -l) -gt 0 ]; then
                    logit Continue basecalling $rundir $(ls $input_dir | grep -c ".fast5$") fast5 files remaining, working on $(ls $tmpdir/fast5 | grep -c ".fast5$")

                    # basecalling parameters:
                    guppy_basecall_client -i $tmpdir/fast5 -s $tmpdir/basecalling -c $BCConfigPath --barcode_kits $BCBarcodeKit --compress_fastq --num_callers 2 --port --port "ipc:///tmp/.guppy/5555" --disable_pings

                    # sync back to main rundir (fastq_pass)
		    tmp_hash=$(basename $tmpdir)
		    tmp_hash=${tmp_hash%%tmp.}
		    for barcode in $(ls $tmpdir/basecalling/pass); do
                       mkdir -p $rundir/fastq_pass/$barcode
                       ls $tmpdir/basecalling/pass/$barcode | xargs --no-run-if-empty -I {} mv $tmpdir/basecalling/pass/$barcode/{} $rundir/fastq_pass/$barcode/basecalled_$tmp_hash"_"{}
		    done
                    rm -rf $tmpdir/basecalling
                else
                    logit "WARNING: endless loop, trapped in basecalling?"
                fi
            done
            logit "Stop basecalling"
        fi
    done
}

### MAIN ###

# abort if backup is still running
if [ -f $pidFile ]; then
    logit "Backup still running!"
    exit 0
else
    touch $pidFile
fi

# abort if backup host not responding to ping
if NetworkUnavailable; then
    logit "Host not available, no Backup possible"
    rm $pidFile
    exit 1
fi

# abort if backup drive can't be connected
if NetworkNotConnected; then
    if NetworkNotConnected; then
        logit "Could not reconnect remote server, aborting"
        rm $pidFile
        exit 1
    fi
fi

# if we reach this point, we can start backup/check for files to be backed up
for dir in $(ls $OutputBase); do
    RunDir=$OutputBase/$dir
    for subRunDir in $RunDir/*/*/{fastq_pass,fast5}; do
        if [ -d $subRunDir ]; then
            flag_file_finished=$(dirname $subRunDir)/final_summary* #dirname!!!
            subdir=$(dirname $subRunDir | sed 's~'$OutputBase'/~~;')
            if [ -f $flag_file_finished ]; then
                if [ -d $BackupDir/$subdir ]; then
                    if BackupComplete $subdir; then
                        BackupRunDir $(dirname $subRunDir) $subdir
                    fi
                else
                    CompleteBasecalling $(dirname $subRunDir)
		    BackupRunDir $(dirname $subRunDir) $subdir 
                fi
            else
                logit "Incomplete rundir, not copying: $subRunDir"
                CompleteBasecalling $(dirname $subRunDir)
            fi
        fi
    done
done
            
rm $pidFile
