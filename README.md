# simultaneous_basecall_mk1c
**THE SOLUTION PROVIDED IS MAINLY A WORKAROUND, USE AT YOUR OWN RISK**  
Workaround for simultaneous basecalling at MinIon Mk1C and backup script.  
This bash-script can be used to automatically copy finished nanopore sequencing runs to backup drives. In addition, it provides simultaneous basecalling of fast5 output if basecalling is disabled because of performance issues.  

## usage
This script is best configured as cron job (see below), but also works when called interactively. It will not work out the the box, take time to adapt to your needs.

## configuration:
### Adaptions required:
Edit the first lines of the script:
```bash
Location=yourlocation
Hostname=$(hostname)
BackUpSubdir=$Hostname
BackupHost=yourbackuphost
```
`Location` is a layer added to have multiple workgroups use the same backup drive  
`BackupHost` is the name of your backup host  

Additionally you might want to edit the basecalling settings:  
```bash
BCBarcodeKit=SQK-RBK110-96
BCConfigPath=/opt/ont/guppy/data/dna_r9.4.1_450bps_fast.cfg
BCChunkSize=30 #number of fast5 files to be processed per basecall_client call
```

### Configure network
The backup requires a stable mount point that is listed in `/etc/fstab` so that it can be reconnected if needed using `mount`. Default mountpoint set in this script is `/mnt/sequencer/`

### Configure as root-cronjob
If automatic re-connection is to work, the script has to be run as root. Non-root cron-jobs also work, but network re-connection needs to be resolved manually (if that's an issue). I recommend running the script in an interval of 15 minutes.
add to crontab:
`sudo crontab –e`
```crontab
*/15 * * * * /home/minit/backup_sequencingrun_nanopore.sh
```
