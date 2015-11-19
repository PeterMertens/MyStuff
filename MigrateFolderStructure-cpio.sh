#!/usr/bin/sh
#
# Author: Peter Mertens <pmertens@its.jnj.com>
#
# This script will copy files from 1 directory tree to another while excluding
# all directories that match a certain mask (e.g. backup|archive|...)
#
# $Revision$
# $Date$
# $Header$
# $Id$
# $Locker$
# History: Check the bottom of the file for revision history
# ----------------------------------------------------------------------------

typeset -i count=0
typeset -i totalcount=0
typeset -i start_cpio_threshold=10000 # start cpio thread after exceeding threshold
typeset -i iteration=1000 # display count every iteration
typeset -i max_threads=3  # do not run more than max_threads at the same time
typeset -i thread_seq=0   # sequence number for threads
typeset    file_prefix=/var/tmp/MigrateFolderStructure_$(date +'%Y%m%d%H%M')_$$
typeset    selected_files=${file_prefix}_selected_files_$$.txt
typeset    su_user # user that will create the target folder structure
                   # the script must be run as root in order to su without password
typeset -l log_level=high

typeset -ft Usage
typeset -ft Log
typeset -ft StartCPIOThread
typeset -ft ProcessDirectory

# ------------------------------------------------------------------------------
function Usage {
prog=$1
shift
echo $*
cat - <<EOT
--------------------------------------------------------------------------------
Usage: $prog -s source-folder -t target-folder -u username [-d count] 
                [-m max_threads] [-T start_cpio_threshold] [-l high|medium|low]

       This script can be used to transfer files from one directory tree to 
       another, excluding files in directories names /backup*, /arch* 
       or /reorg... (case insensitive).

Options:
       -s source-folder
       -t target-folder
       -u username. Files will be read as root, but will created as specified user. 
       -d count. Display a status message after selecting <count> files.
          default=1000
       -m max_threads. Number of cpio jobs that are allowed to be run simultaneously.
          Do not put this too high otherwise it will impact performance of the system.
          default=3  
       -T start_cpio_threshold
          cpio jobs will only be started if at least <start_cpio_threshold> number 
          of files have been selected.  This number will only be checked after
          selecting all files in one folder, to avoid running one folder in different
          threads.
          The default value is 10000.  Note that if a single folder contains more than
          10000 files, the cpio will not be started after 10000 files but rather after 
          selecting all files in that folder.
       -l log-level [high|medium|low]
          default=high

Examples:
cd  /export/ppr/data/CON; /home/pmertens/MigrateFolderStructure-cpio.sh -s . -t /NEW/CON -u CONadm -T 5000 -d 100 -m 4
cd  /export/ppr/data; /home/pmertens/MigrateFolderStructure-cpio.sh -s CON -t /NEW/CON -u CONadm -T 5000 -d 100 -m 4
EOT
exit
}

# ------------------------------------------------------------------------------
function Log {
level=$1
case ${log_level} in
       low) [[ ${level} -gt 1 ]] && return ;;  # only list errors 
    medium) [[ ${level} -gt 2 ]] && return ;;  # only list errors and interesting info
         *) ;;                                 # list everything
esac
echo $(date '+%Y-%m-%d %H:%M:%S') $*
}

# ------------------------------------------------------------------------------
function StartCPIOThread {
if [[ $count -eq 0 ]]
then Log 2 "INFO: nothing selected for transfer"
else Log 2 "INFO: $count files selected for transfer"
     (( totalcount += count )) # Keep track of number of files to copy
     count=0 # reset for next transfers
     (( thread_seq = thread_seq + 1 ))
     cpio_input=${file_prefix}_cpio_thread_${thread_seq}.dat
     cpio_log=${file_prefix}_cpio_thread_${thread_seq}.log
     Log 2 "INFO: cpio_input: ${cpio_input}"
     Log 2 "INFO:   cpio_log: ${cpio_log}"

     Log 3 "INFO: check how many threads are active"
     while [[ `jobs | wc -l` -ge ${max_threads} ]]
     do
         sleep 1
     done

     mv ${selected_files} ${cpio_input} || {
        Log 1 "ERROR: Failure in mv  mv ${selected_files} ${cpio_input}"
        exit
        }

     (cat ${cpio_input} | cpio -oA | su ${su_user} -c "cd \"${main_to}\"; cpio -iUmd") > ${cpio_log} 2>&1 &
     Log 2 "INFO: cpio started in background with pid $!."
fi
}

# ------------------------------------------------------------------------------
function ProcessDirectory {
typeset    from=$1
typeset    file
typeset -u u_dir # uppercase directory name for case insensitive pattern matching

Log 3 "INFO: Starting to process ${from}"

# Now start looking at the contents of this dir
# We use the ls ${from} | while construction because a for file in construction gives
# problems when folder names contain spaces
# Also 'ls ${from}/*' is not possible, because in case of huge directories
# this will lead to arg list too long...

ls "${from}" | while read file 
do
    if   [[ -d "${from}/${file}" ]] # this is another subfolder
    then echo ${from}/${file} >> ${selected_files} # always select directory, so that also empty directories 
	                                           # and even the archive/backup directories will be created
         (( count = count + 1 ))
	 u_dir="${file}" # put in uppercase for pattern matching
         if [[ "${u_dir}" = ?(BACKUP*|ARCH*|REORG*) ]]
         then Log 2 "INFO: Skipping backup/arch/reorg directory: ${from}/${file}"
              continue
         else ProcessDirectory "${from}/${file}" 
         fi
    else echo ${from}/${file} >> ${selected_files}
         (( count = count + 1 ))
    fi
    [[ $(( count % iteration )) -eq 0 ]] && Log 2 "INFO: Progress: $count files selected / total-count=$totalcount / ${from}/${file}"
done 

[[ $count -gt $start_cpio_threshold ]] && StartCPIOThread # Enough files to start the transfer

return # End of ProcessDirectory Function
}

# ------------------------------------------------------------------------------
# MAIN -------------------------------------------------------------------------

# Argument Handling

while getopts ":s:t:u:d:m:T:l:" opt; do
        case $opt in
                :) Usage $0 "argument missing for option ${OPTARG}" ;;
                s) main_from=${OPTARG} ;;
                t) main_to=${OPTARG} ;;
                u) su_user=${OPTARG} ;;
                d) iteration=${OPTARG} ;;
                m) max_threads=${OPTARG} ;;
                T) start_cpio_threshold=${OPTARG} ;;
                l) log_level=${OPTARG} ;;
                ?|h) Usage $0 ;;
        esac
done
shift $(( OPTIND-1 ))
[[ -z ${main_from} ]] && Usage $0 "-s is missing"
[[ -z ${main_to}   ]] && Usage $0 "-t is missing"
[[ -z ${su_user}   ]] && Usage $0 "-u is missing"
[[ ${log_level}  != ?(high|medium|low) ]] && Usage $0 "log_level should be high, medium or low"

# Show What We Got

cat - <<EOT
--------------------------------------------------------------------------------
current working directory: $(pwd)
                   source: ${main_from}
                   target: ${main_to}
                  su_user: ${su_user}
     start_cpio_threshold:${start_cpio_threshold} # start cpio thread after exceeding threshold
                iteration:${iteration} # display count every iteration
              max_threads:${max_threads}  # do not run more than max_threads at the same time
           selected_files:${selected_files}
               all files start with ${file_prefix}
--------------------------------------------------------------------------------
EOT

Log 2 "INFO: $0 is starting"

# Sanity checks

### old dtksh equivalent [[ ${main_from:0:1} == "/" ]] && {
[[ $(expr substr "$main_from" 1 1 ) = "/" ]] && {

    Log 1 "ERROR: ${main_from} MUST be a relative path and should not start with /."
    exit
    }

[[ ! -d ${main_from} ]] && {
    Log 1 "ERROR: ${main_from} isn't a directory."
    exit
    }

pwget -n ${su_user} > /dev/null || {
    Log 1 "ERROR: ${su_user} is not a valid username."
    exit
    }

type=$(su ${su_user} -c "file ${main_to}")
[[ ${type##*	} != "directory" ]] && {
    Log 1 "ERROR: ${main_to} isn't a directory."
    exit
    }

# Start the work

ProcessDirectory "${main_from}" 

# Complete the work

StartCPIOThread # Don't forget to copy the last files

Log 2 "INFO: Check all logs in ${file_prefix}_cpio_thread_*.log"
Log 2 "INFO: $totalcount files processed."
Log 2 "INFO: jobs still running will be listed here."
jobs
Log 2 "INFO: wait for possible jobs to be completed."
wait
Log 2 "INFO: $0 completed"

exit
