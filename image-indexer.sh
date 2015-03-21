#!/bin/bash

if [ "$1" == "--help" ]
then
    echo '
image-indexer
-------------

This script searches directories for JPEG files and copies them to a repository
directory.  It uses an SQLite database to control which directories to search
and to record all images, the files containing each image and the EXIT tags
attached to each file.

When the script starts, it determines if the database exists and is valid,
(re)creating it if it isn'\''t.  It then checks if there are any entries in the
"process_queue" table.  This table lists the image files that have been
discovered but have not been processed.  If the queue is empty, a search of the
directories listed in the "search_dir" table is made for JPEG file, with the
result being stored in the process queue.  The "search_dir" table has a
priority column to indicate the order in which the directories should be
processed.  When the database is created the "search_dir" table is initially
populated from a file called "image-indexer-search-directories", which has one
line per search directory with each line consisting of a priority number, some
white space then the path of the directory.  These paths should appear to be
on the localhost (although they can be on a remote host but mounted locally,
using, for example, the Samba protocol).  The files are copied using rsync
over SSH so the bandlidth can be limited.  Because of this, please ensure
passwordless SSH authentication is set up to localhost.

The script then iterates over each JPEG file in the process queue.  It copies
the file to a local temporary directory, extracts its EXIF data, calulates a
unique ID of the actual image (with the EXIF tags), copies the file to the
repository and record the two files containing the image: i.e., the original
file and the file copied into the repository.  The extracted EXIF tags are also
stored in the database.  Then, it uploads the file to an AWS S3 bucket,
using trickle to limit the transfer rate.

Send the process a hang-up (1), interrupt (2) or quit (3) signal to request it
to stop when it has finished process the current file.
'
    exit
fi


##  CONSTANTS  ##

verbose=-v
dryrun= #--dry-run
copy_to_local_repo=false
base_dir=$HOME/image-indexer
run_dir=$base_dir/run
dst_dir=$run_dir/images
tmp_dir=/tmp/image-indexer
meta=$tmp_dir/$$.meta
path_copy=$tmp_dir/$$.orig
path_pure=$tmp_dir/$$.pure
database=$run_dir/image.db
database_copy=$run_dir/image-read.db
dd='\([0-9#][0-9#]\)'
number_of_photos_between_copying_the_database_file=5
number_of_database_copys_between_making_a_backup_file=12
number_of_photos_between_updating_the_website=15
seconds_to_pause_between_each_photo=12
select_next_path_from_top_n_paths=1000
aws_s3_bucket=warwick-wendy-allen--photos
aws_s3_upload_rate_kBps=32
local_network_transfer_rate_kBps=96


##  SIGNAL HANDLING  ##

stop_msg=

function trap_with_arg()
{
    func="$1" ; shift
    for sig ; do
        trap "$func $sig" "$sig"
    done
}

trap_with_arg stopRequested SIGHUP SIGINT SIGQUIT

function stopRequested()
{
    stop_msg="SIGHUP or SIGINT received: This script will stop once the current file has been processed."
    if [ $verbose ]; then echo $stop_msg; fi
    echo "Signal $1 received." 1>&2
}

function stopIfRequested()
{
    if [ ! -z "$stop_msg" ]
    then
        echo "Stopping in response to a SIGHUP or SIGINT."
        i=1     # Count until next DB copy.
        j=1     # Count until next DB backup.
        k=1     # Count until next website refresh.
        copyDatabase
        updateWebsite
        echo "Stopping at $(date)."
        exit 0
    fi
}


##  FUNCTIONS  ##

function dbCreate()
{
    echo "Creating the image-indexer database." 1>&2
    if [ -z "$dryrun" ]
    then
        # Create the schema.
        sqlite image.db <$base_dir/image-create.sql
        # Insert some set-up data from text files.
        sed -e"s/'/''/g" -e's,\\,\\\\,g' -e"s/^[^0-9]*\([0-9]\)\+\s\+\(.*[^\s]\).*$/INSERT INTO search_dir (path, priority) VALUES ('\2', \1);/" <$base_dir/image-indexer-search-directories | \
        sqlite $database
        sed -e"s/'/''/g" -e's,\\,\\\\,g' -e"s/^[^0-9]*\([0-9]\)\+\s\+\(.*[^\s]\).*$/INSERT INTO type       (typeId, type)   VALUES ('\1', '\2');/" <$base_dir/image-indexer-types              | \
        sqlite $database
    fi
}

function sqlEscape()
{
    echo "$*" | sed -e"s/'/''/g" -e's,\\,\\\\,g'
}

function dbDo()
{
    if [ $verbose ]
    then
        echo "$*" 1>&2
    fi
    if [ -z "$dryrun" ]
    then
        echo "$*" | sqlite $database
    fi
}

function getNextSourcePath()
{
    dbDo "SELECT path FROM process_queue LIMIT $select_next_path_from_top_n_paths;" | sort --random-sort | head -1
}

function dbInsertFileAndTag()
{
    path="$1"
    file_time=$(stat --format=%Y "$path")
    path_sql_escaped=$(sqlEscape "$path")
    dbDo "
        DELETE FROM file WHERE path = '$path_sql_escaped';
        INSERT INTO file (fileId, path, imageId, size, time) VALUES (NULL, '$path_sql_escaped', $image_id, $file_size, $file_time);
        SELECT fileId FROM file WHERE path='$path_sql_escaped';
    " | \
    (
        read file_id
        perl -lne ' 
            /(\S*)\s*(.*)/;
            ($key,$val)=($1,$2);
            $q=chr(39);
            $val =~ s/$q/"/g;
            $val =~ s/[^!-~\s]//g;
            $_ = "INSERT OR REPLACE INTO tag (fileId, key, value) VALUES ('$file_id', $q$key$q, $q$val$q);";
            print STDERR if length("'$verbose'");
            s/^/-- / if length("'$dryrun'");
            print;
        ' <$meta | sqlite $database
    )
}

function isVideo() {
     [[ "$source_path" =~ \.[Mm][Oo][Vv]$ ]]
}

function copyDatabase()
{
    i=$(($i - 1))
    if [[ $i > 0 ]]
    then
        if [ $verbose ]
        then
            printf "There are %3d photos remaining until the next copy of the write-to database file, ${database}, to the read-from database file, ${database_copy}.\n" $i
            printf "There are %3d copy events (from ${database} to ${database_copy}) until the next back-up and compress of ${database_copy}.\n" $j
        fi
	return
    fi

    cp $verbose $database $database_copy
    i=$number_of_photos_between_copying_the_database_file
    j=$(($j - 1))
    if [[ $j == 0 ]]
    then
        if [ $vebose ]
        then
            ls -ltsdr --color=tty image*.db*;
        fi
        if [ -e "$backup" ]
        then
            nice bzip2 $verbose $backup &
        fi
        backup=$database.$(date +%Y%m%d-%H%M)
        cp $verbose $database_copy $backup
        j=$number_of_database_copys_between_making_a_backup_file
    elif [ $verbose ]
    then
        printf "There are %3d copy events (from ${database} to ${database_copy}) until the next back-up and compress of ${database_copy}.\n" $j
    fi

    if [ $verbose ]
    then
        date
        echo 'SELECT "Queue: ", COUNT(*) FROM process_queue; SELECT "Images:", COUNT(*) FROM image; SELECT "Files: ", COUNT(*) FROM file; SELECT "Tags:  ", COUNT(*) FROM tag;' | sqlite -separator ' | ' $database_copy
        echo
    fi
}

function updateWebsite()
{
    k=$(($k - 1))
    if [[ $k > 0 ]]
    then
        if [ $verbose ]; then echo "The website will be updated after $k more photos have been processed."; fi
        return
    fi
    # Create a slide-show website.
    pushd $base_dir
    perl image-indexer-create-website.pl $verbose
    popd
    k=$number_of_photos_between_updating_the_website
}


##  SET-UP  ##

if [ $verbose ]; then set -v; set -x; fi
mkdir -p $tmp_dir
mkdir -p $run_dir
cd $run_dir

# Create the database if it doesn't exist.
if [ ! -e image.db ]
then
    dbCreate
fi

# Check if the actual schema is really what is should be.
if [[ $(echo '.schema' | sqlite image.db | grep -v ^$ | wc -l) -ne $(cat $base_dir/image-create.sql | grep -v ^$ | grep -v ^#-- | wc -l) ]]
then
    # The DB is corrupted.  Nuke it.
    rsync -v $dryrun image.db image.`date +%s`.db
    dbCreate
fi



##  MAIN  ##

echo "

Starting at $(date)
PID: $$
"

# Get the image files to process (unless there aleady exists a list of files waiting to be processed).
path_cnt=$(dbDo 'SELECT COUNT(*) FROM process_queue;')
if [[ "$path_cnt" -lt "1" ]]
then
    echo -n 'Refreshing the process queue at ' 1>&2
    date 1>&2
    search_dirs=$(dbDo 'SELECT path FROM search_dir ORDER BY priority;' | sed -e's/[\s()]/\\&/g')
    if [ -z "$search_dirs" ]
    then
        echo "No search directories are loaded into the database ($database)." 1>&2
        exit 1
    fi
    dbDo $(
        find $search_dirs -type f -iregex '.*\.\(jpe?g\|mov\)' | \
        sed -e"s/'/''/g" -e's,\\,\\\\,g' -e"s/^/INSERT INTO process_queue (path) VALUES ('/" -e"s/$/');/"
    )
fi

i=1     # Count until next DB copy.
j=1     # Count until next DB backup.
k=1     # Count until next website refresh.

# Process each image file.
source_path=$(getNextSourcePath)
backup=$database.$(date +%Y%m%d-%H%M)
while [ ! -z "$source_path" ]
do
    copyDatabase
    updateWebsite

    if [ -r "$source_path" ]
    then
        if [ $verbose ]; then printf "\nCopying '$source_path' to '$path_copy' at $local_network_transfer_rate_kBps kBps.\n"; fi
        if [ $verbose ]
        then
            rsync -vv --progress --bwlimit=$local_network_transfer_rate_kBps localhost://"'$source_path'" "$path_copy"
        else
            rsync --bwlimit=$local_network_transfer_rate_kBps localhost://"'$source_path'" "$path_copy"
        fi
        cp $path_copy $path_pure

        if isVideo
        then
            file_extn=mov
            avconv -i $path_copy showinfo 2>&1 | \
            perl -nwle '
                BEGIN {our $stream = q{}}
                our $stream;
                while ( /\G.*?\b(?:(?<key>creation_time|bitrate|Video|Audio)\s*:\s*(?<val>.*?)$|(?<key>Duration|start)\s*:\s*(?<val>.*? ),|(?<stream>Stream\s#.*?):)/msg )
                {
                    if (defined $+{stream})
                    {
                        $stream = qq{$+{stream}};
                        $stream =~ s/[^\w]+/_/g;
                        $stream .= q{.};
                        next;
                    }
                    printf q{%-45s %s}.chr(10), $stream.$+{key}, $+{val};
                }' >$meta

            date=$(awk '/creation_time / {print $2" "$3 }' <$meta | head -1 | sed s/-/:/g)
        else
            file_extn=jpg
            exiv2 -Pkt $path_copy | sed -e's/\\/\\\\/g' -e"s/'/''/g" >$meta
            jhead -purejpg $path_pure >/dev/null

            comment=$(awk '/^Exif\.Photo\.UserComment / {for (i=2; i<=NF; i++) print $i}' <$meta)
            path_components=$(perl -we '$_ = shift; s/\.jpe?g$//i; @pc = split "/"; print join "; ", grep defined, @pc[$#pc-2 .. $#pc]' "'$source_path'")
            exiv2 -M"set Exif.Photo.UserComment $path_components" $path_copy

            height=$( awk '/^Exif\.Photo\.PixelXDimension / {printf "%06d", $2}' <$meta)
            width=$(  awk '/^Exif\.Photo\.PixelYDimension / {printf "%06d", $2}' <$meta)
            date=$(   awk '/^Exif\.Image\.DateTime        / {print $2" "$3    }' <$meta)
            if [[ -z "$height" ]]; then height="NULL";              fi
            if [[ -z "$width"  ]]; then width="NULL";               fi
        fi

        if [[ -z "$date"   ]]; then date="####:##:## ##:##:##"; fi
        year_month=$(echo "$date" | sed -e "s/$dd$dd:$dd:$dd $dd:$dd:$dd/\1\2-\3/")
        day_time=$(  echo "$date" | sed -e "s/$dd$dd:$dd:$dd $dd:$dd:$dd/\4-\5\6/")
        digest=$(openssl dgst -sha384 -binary <$path_pure | openssl enc -base64 | sed -e's/\//-/g')
        file_size=$(stat --format=%s $path_copy)
        compressed_size=$(stat --format=%s $path_pure)
        compressed_size_base64=$(echo 'ibase=10;obase=16;'$compressed_size | bc | base64 | xargs printf "%12s" | sed -e's/ /=/g')  # Left-padded to be at least 12 characters long.
        image_type=$(if isVideo; then echo 2; else echo 1; fi)

        dbDo $(echo "
            DELETE FROM image WHERE digest = '$digest';
            INSERT INTO image (imageId, digest, type, compressedSize) VALUES (NULL, '$digest', $image_type, $compressed_size);
        ")
        image_id=$(dbDo "SELECT imageId FROM image WHERE digest='$digest';")
        dbInsertFileAndTag "$source_path"

        canoncical_name=$year_month.$day_time.$digest.$compressed_size_base64.$file_extn

        # Copy to local repository.
        if $copy_to_local_repo
        then
            touch --reference="'$source_path'" $path_copy
            mkdir -p $verbose $dst_dir/$year_month
            destination_path=$dst_dir/$year_month/$canoncical_name
            if [ $verbose ]
            then
                rsync -avv --progress $dryrun "$path_copy" "$destination_path"
            else
                rsync -a $dryrun "$path_copy" "$destination_path"
            fi
            dbInsertFileAndTag "$destination_path"
        fi

        # Upload to AWS S3 bucket.
        if ! s3cmd info s3://$aws_s3_bucket/$canoncical_name 2>/dev/null
        then
            cmd="trickle -s -u$aws_s3_upload_rate_kBps s3cmd put -P '$path_copy' s3://$aws_s3_bucket/$canoncical_name"
            if [ $verbose ]
            then
                echo "
    Uploading to the AWS S3 bucket:
        $cmd"
            fi
            if [ "$dryrun" != "--dry-run" ]
            then
                $cmd
                echo
            fi
        fi
    fi
    source_path_sql_escaped=$(sqlEscape "$source_path")
    dbDo "DELETE FROM process_queue WHERE path = '$source_path_sql_escaped';"

    if [ $verbose ]; then set +x; set +v; fi
    stopIfRequested

    # Wait to let the network breath.
    sleep_seconds=$seconds_to_pause_between_each_photo
    if [ $verbose ]; then echo -n "Waiting a while before processing the next file ...   "; fi
    while [[ $sleep_seconds > 0 ]]
    do
        if [ $verbose ]; then printf "\b\b\b%3d" $sleep_seconds; fi
        sleep 1
        stopIfRequested
        sleep_seconds=$(( $sleep_seconds - 1 ))
    done
    if [ $verbose ]; then printf "\b\b\b waited $seconds_to_pause_between_each_photo seconds.\n\n"; fi

    source_path=$(getNextSourcePath)
done
