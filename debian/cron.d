# By default pgdumper expects to run once a day.
# You can adjust when in the day it runs with relative safety.

# If an expert wants to run it twice a day (such as 7am and 10pm), they'll need to change
# the 'backupinterval' variable in /usr/bin/pgdumper.pl to 43200 (ie seconds in 12 hrs).
01 22 * * * postgres /usr/bin/pgdumper.pl >> /var/log/pgdumper/pgdumper.log 2>&1
