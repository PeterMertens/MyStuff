#!/usr/bin/sh
#
# Author: Peter Mertens <pmertens@its.jnj.com>
#
# This script will copy files from 1 directory tree to another while excluding
# all directories that match a certain mask (e.g. backup|archive|...)
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
                   # if you use the su_user then the script must be run as root
                   # in order to su without password
typeset -l log_level=high
typeset -l select=all

typeset -ft Usage
typeset -ft Log
typeset -ft StartCPIOThread
typeset -ft ProcessDirectory

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
function Usage {
prog=$1
shift
echo $*
cat - <<EOT
--------------------------------------------------------------------------------
Usage: $prog -s source-folder -t target-folder -u username [-d count] 
                [-m max_threads] [-T start_cpio_threshold] [-l high|medium|low]
                [-S all|old|new]

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
       -S [all|old|new]
          all = select all files from any folder
          old = select only files from folders having [backup*|archive*|reorg*] in their name
		or from any subfolder under an old directory
          new = the opposite of old
          default=all

Examples:
cd  /source/subdir; /somewhere/MigrateFolderStructure-cpio.sh -s . -t /target/subdir -u username -T 5000 -d 100 -m 4
cd  /source; /somewhere/MigrateFolderStructure-cpio.sh -s subdir -t /target/subdir -u username -T 5000 -d 100 -m 4
EOT
exit
}

# ------------------------------------------------------------------------------
function StartCPIOThread {
if [[ $count -eq 0 ]]
then Log 2 "INFO: ($0 1) nothing selected for transfer"
else Log 2 "INFO: ($0 2) $count files selected for transfer"
     (( totalcount += count )) # Keep track of number of files to copy
     count=0 # reset for next transfers
     (( thread_seq = thread_seq + 1 ))
     cpio_input=${file_prefix}_cpio_thread_${thread_seq}.dat
     cpio_log=${file_prefix}_cpio_thread_${thread_seq}.log
     Log 2 "INFO: ($0 3) cpio_input: ${cpio_input}"
     Log 2 "INFO: ($0 4)   cpio_log: ${cpio_log}"

     Log 3 "INFO: ($0 05) check how many threads are active"
     while [[ `jobs | wc -l` -ge ${max_threads} ]]
     do
         sleep 1
     done

     mv ${selected_files} ${cpio_input} || {
        Log 1 "ERROR: ($0 06) Failure in mv  mv ${selected_files} ${cpio_input}"
        exit
        }

     if [ -z "${su_user}" ]
     then (cat ${cpio_input} | cpio -oA | sh            -c "cd \"${main_to}\"; cpio -iUmd") > ${cpio_log} 2>&1 &
     else (cat ${cpio_input} | cpio -oA | su ${su_user} -c "cd \"${main_to}\"; cpio -iUmd") > ${cpio_log} 2>&1 &
     fi

     Log 2 "INFO: ($0 07) cpio started in background with pid $!."
fi
}

# ------------------------------------------------------------------------------
# ProcessDirectory will select all files in a directory and depending on the
# -S option it will descend in subdirs.
# -S all --> select all files and descend in all sub-directories
# -S old --> only select files residing in directory-trees that have 'backup',
#            'arch' or 'reorg' in the name.  The names are not case-sensitive.
#            Any sub-dirs of these so called 'old' directories are also 
#            considered old. The function will still descend in 'new' folders
#            but won't select files in those new directories.  It will merely
#            descend to search for 'old' dirs.
# -S new --> only select files that do not reside in old directory trees
#            (so this is the opposite of -S old). Does not descend in 'old'
#            directories.
#
# Arguments:
#  $1 - the folder to process
#  $2 - foldertype (all, old or new)
#       all: process all files and subdirectories from here.  This will be set
#            if -S all has been chosen for the entire directory tree!
#       old: foldertype will be set to old only if -s old has been chosen AND
#            if we're processing a directory having an old directory somewhere
#            up in its hierarchy
#       new: foldertype will be set to new only if -s new has been chosen AND
#            if we're processing a directory that doesn't have an old directory
#            somewhere up in its hierarchy.
# ------------------------------------------------------------------------------
function ProcessDirectory {
typeset    from=$1
typeset    foldertype=$2
typeset    file
typeset -u u_dir # uppercase directory name for case insensitive pattern matching

Log 3 "INFO: ($0 01) Starting to process ${from}"

# Now start looking at the contents of this dir
# We use the ls ${from} | while construction because a for file in construction gives
# problems when folder names contain spaces
# Also 'ls ${from}/*' is not possible, because in case of huge directories
# this will lead to arg list too long...

ls "${from}" | while read file 
do
    if   [[ -d "${from}/${file}" ]] # this is another subfolder
    then case ${foldertype} in
              all|old) echo ${from}/${file} >> ${selected_files} # always select directory so that also empty directories will be created
                       (( count = count + 1 ))
                       ProcessDirectory "${from}/${file}" "${foldertype}"
                       ;;
              new) u_dir="${file##*/}" # put in uppercase for pattern matching and remove any parent directory
                   if [[ "${u_dir}" = ?(BACKUP*|ARCH*|REORG*) ]]
                   then # this is an old directory
                        if [[ "${select}" = "old" ]]
                        then Log 3 "INFO: ($0 02) Selecting backup/arch/reorg directory: ${from}/${file} and any subfolders"
                             echo ${from}/${file} >> ${selected_files} # always select directory so that also empty directories will be created
                             (( count = count + 1 ))
                             ProcessDirectory "${from}/${file}" "old"
                        else # select will be new since it wasn't old (see if clause) and it can't be 'all' because then foldertype would also be 'all'
                             Log 3 "INFO: ($0 03) Skipping backup/arch/reorg directory: ${from}/${file} and any subfolders"
                        fi
                   else # this is a new directory
                        if [[ "${select}" = "old" ]]
                        then # do not select this directory but do descend in order to check possible other subfolders
                             # cpio will create any parent directory if we would find old subfolders down in this hierarchy
                             ProcessDirectory "${from}/${file}" "new"
                        else # select will be new since it wasn't old (see if clause) and it can't be 'all' because then foldertype would also be 'all'
                             echo ${from}/${file} >> ${selected_files} # always select directory so that also empty directories will be created
                             (( count = count + 1 ))
                             ProcessDirectory "${from}/${file}" "new"
                        fi
                   fi
                   ;;
               *) Log 1 "ERROR: ($0 04) Invalid value for foldertype: ${foldertype}"
                  exit
                  ;;
         esac
    else [[ "$foldertype" != "${select}" ]] && continue # don't process any files if we're just traversing this dir
         echo ${from}/${file} >> ${selected_files} # This is a file (or more correct: not a directory)
         (( count = count + 1 ))
    fi

    [[ $(( count % iteration )) -eq 0 ]] && Log 2 "INFO: ($0 04) Progress: $count files selected / total-count=$totalcount / ${from}/${file}"

    [[ $count -gt $start_cpio_threshold ]] && StartCPIOThread # Enough files to start the transfer
done 


return # End of ProcessDirectory Function
}

# ------------------------------------------------------------------------------
# MAIN -------------------------------------------------------------------------

typeset -u U_dir # uppercase directory name for case insensitive pattern matching

# Argument Handling
while getopts ":s:t:u:d:m:T:l:S:" opt; do
        case $opt in
                :) Usage $0 "argument missing for option ${OPTARG}" ;;
                s) main_from=${OPTARG} ;;
                t) main_to=${OPTARG} ;;
                u) su_user=${OPTARG} ;;
                d) iteration=${OPTARG} ;;
                m) max_threads=${OPTARG} ;;
                T) start_cpio_threshold=${OPTARG} ;;
                l) log_level=${OPTARG} ;;
                S) select=${OPTARG} ;;
                ?|h) Usage $0 ;;
        esac
done
shift $(( OPTIND-1 ))
[[ -z ${main_from} ]] && Usage $0 "-s is missing"
[[ -z ${main_to}   ]] && Usage $0 "-t is missing"
[[ ${log_level}  != ?(high|medium|low) ]] && Usage $0 "-l log_level should be high, medium or low"
[[ ${select}     != ?(old|new|all)     ]] && Usage $0 "-l select should be old, new or all"

# Show What We Got

cat - <<EOT
------------------------------------------------------------------------------------------------------------------------
     current working directory: $(pwd)
-s                      source: ${main_from}
-t                      target: ${main_to}
-u                     su_user: ${su_user}
-T        start_cpio_threshold: ${start_cpio_threshold} # start cpio thread after exceeding threshold
-d                   iteration: ${iteration} # display count every iteration
-m                 max_threads: ${max_threads}  # do not run more than max_threads at the same time
-l                   log_level: ${log_level}
-S         wich dirs to select: ${select} (all = everything; 
                                     old = folder names starting with backup, arch or reorg including subfolders;
                                     new = opposite of old)
(temp files)    selected_files: ${selected_files}
 all temporary files start with ${file_prefix}
------------------------------------------------------------------------------------------------------------------------
EOT

Log 2 "INFO: ($0 01) $0 is starting"

# Sanity checks

### old dtksh equivalent [[ ${main_from:0:1} == "/" ]] && {
[[ $(expr substr "$main_from" 1 1 ) = "/" ]] && {

    Log 1 "ERROR: ($0 02) ${main_from} MUST be a relative path and should not start with /."
    exit
    }

[[ ! -d ${main_from} ]] && {
    Log 1 "ERROR: ($0 03) ${main_from} isn't a directory."
    exit
    }

if [[ -n "${su_user}" ]] # su_user option has been used
then pwget -n ${su_user} > /dev/null || {
         Log 1 "ERROR: ($0 04) ${su_user} is not a valid username."
         exit
         }

     type=$(su ${su_user} -c "file ${main_to}")
     [[ ${type##*	} != "directory" ]] && { # note there's a TAB char in ${type##*	}
         Log 1 "ERROR: ($0 05) ${main_to} isn't a directory."
         exit
         }
else
     type=$(file "${main_to}")
     [[ ${type##*	} != "directory" ]] && { # note there's a TAB char in ${type##*	}
         Log 1 "ERROR: ($0 06) ${main_to} isn't a directory."
         exit
         }
fi

# Before starting to process the main_from directory, we will first check if it's an
# old directory [BACKUP*|ARCH*|REORG*] (in case we want to select only old or only 
# new files)

if [[ "${select}" = "all" ]]
then ProcessModeTopLevel="all" # this option doesn't care about the type of directory
else U_dir=$(basename ${main_from}) # get the name of the lowest level dir and make it uppercase
          # we use basename for this and not ${main_from##*/} because main_from might end 
          # in / and basename is so friendly to always return the last part of the path
     [[ "${U_dir}" = "." ]] && U_dir=${PWD##*/} # we look at the PWD in case main_from=.
     if [[ "${U_dir}" = ?(BACKUP*|ARCH*|REORG*) ]]
     then # this is an old type starting directory
          # only select old files if the starting directory is old type
          if [[ "${select}" = "old" ]]
          then ProcessModeTopLevel="old"
          else Log 1 "ERROR: ($0 07) -s ${main_from} (=${U_dir} is an old type directory, this conflicts with -S new"
               exit
          fi
     else # this is a new type starting directory
          ProcessModeTopLevel="new"
     fi
fi

# Start the real work

ProcessDirectory "${main_from}" ${ProcessModeTopLevel}

# Complete the work

StartCPIOThread # Don't forget to copy the last files

Log 2 "INFO: ($0 19) Check all logs in ${file_prefix}_cpio_thread_*.log"
Log 2 "INFO: ($0 20) $totalcount files processed."
Log 2 "INFO: ($0 21) jobs still running will be listed here."
jobs

Log 2 "INFO: ($0 22) wait for possible jobs to be completed."
wait

Log 2 "INFO: ($0 23) $0 completed"

exit
