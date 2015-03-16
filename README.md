Image Indexer
-------------

This script searches directories for JPEG files and copies them to a repository
directory.  It uses an SQLite database to control which directories to search
and to record all images, the files containing each image and the EXIT tags
attached to each file.

When the script starts, it determines if the database exists and is valid,
(re)creating it if it isn't.  It then checks if there are any entries in the
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
