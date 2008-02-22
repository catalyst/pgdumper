#!/bin/sh
#
# Dumps all databases for a postgres installation to disk, in preparation for
# them to be backed up.
#
# Author: Peter Bulmer <peterb@catalyst.net.nz>
#
set -e

# Get defaults for ANNOY and BACKUPSSTOREDFOR
. /etc/pgdumper.conf

# Where to put backups. They will be placed in a subdirectory of this grouped
# by cluster. This directory must be owned by the postgres user!
BACKUPDIR=/var/backups/pg

# function to execute something, or die and mail if it fails
function run_or_die() {
  $* 2>/tmp/pg_bak_run-$$
  if [ "$?" -ne "0" ]; then
    echo "Database dump failed!" > /tmp/dump-fail-$$
    echo >> /tmp/dump-fail-$$
    echo "Failed command was: $*" >> /tmp/dump-fail-$$
    echo >> /tmp/dump-fail-$$
    cat /tmp/dump-fail-$$ /tmp/pg_bak_run-$$ | mail -s "[Failure] Database dump on `hostname`" ${ANNOY}
    rm /tmp/dump-fail-$$ /tmp/pg_bak_run-$$
    exit 1
  fi
  # On success, delete the file where errors would have gone.
  rm /tmp/pg_bak_run-$$
}

# Check the script is being run as postgres
USER=`whoami`
if [ "$USER" != "postgres" ]; then
  echo "Postgres DB backup script must be run by user postgres" | mail -s "[FAILURE] Database dump on `hostname`" ${ANNOY}
  exit 1;
fi

# Check the backup directory exists and writable
if [ ! -d $BACKUPDIR ] || [ ! -w $BACKUPDIR ] ; then
  echo "Postgres DB backup directory ${BACKUPDIR} does not exist or is not writable" | mail -s "[FAILURE] Database dump on `hostname`" ${ANNOY}
  exit 1;
fi

# find out what postgres version is out there and run for each
for PGCLUSTER in ` pg_lsclusters --no-header |grep online | cut -d \  --fields=1,6 -s | sed -e 's/ /\//' ` ; do
  #Replace troublesome '/' in cluster name with '-'
  PGCLUSTER_DIR=` echo $PGCLUSTER | sed -e 's/\//-/'`;

  # Check the backup directory exists, make it if it doesn't
  [ -d $BACKUPDIR/pg-${PGCLUSTER_DIR} ] || mkdir $BACKUPDIR/pg-${PGCLUSTER_DIR}

  # work out list of databases
  DBLIST=`psql --cluster ${PGCLUSTER} -t -c "select datname from pg_database where datistemplate = 'f' order by datname asc"`

  # dump all the databases, and compress it
  for DB in ${DBLIST}; do
    DATENOW=`date +%Y%m%d-%H%M%S`
    run_or_die /usr/bin/pg_dump --cluster ${PGCLUSTER} -Fc ${DB} > $BACKUPDIR/pg-${PGCLUSTER_DIR}/pg-${DATENOW}-${DB}.pgdump
  done
done


# clean out old ones
run_or_die find $BACKUPDIR/pg* -type f -mtime +$BACKUPSSTOREDFOR -exec rm \{\} \;

# that's it
