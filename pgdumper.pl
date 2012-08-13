#!/usr/bin/perl

use strict;
use warnings;
use Data::Dumper;
use Time::Zone;
use lib '/usr/share/postgresql-common';
use PgCommon;
use DBI;
use Getopt::Long;
use Sysadm::Install qw(tap);

our %debug = (
    'showcomment' => 1,
    'showcommand' => 0,
    'showresult' => 0,
    'showstdout' => 0,
    'showstderr' => 0,
    'level' => 1,
);

BEGIN {require '/etc/pgdumperconf.pl';}

my $backupdir = '/var/backups/pg';
my $pgversion;

my $backupinterval = 86400; #86400 Seconds = 24 hours

push @skipdb, 'template0';

# Which dump should be overwritten:
my $hanoinumber = determinedumpnumber($backupcopies, $backupinterval, %debug);

# Check that we're running as the postgres user:
my $whoami = `whoami`;
chomp($whoami);
if ($whoami ne 'postgres') {
    print "Error - not running as postgres\n";
    `echo 'Problem(s) were encountered while trying to perform pgdumps' | mail -s "PROBLEM running pgdumps" $annoy`;
    exit(1);
}

# Check that /var/backups/pg/ exists and is writeable:
if (! -w '/var/backups/pg/') {
    print "Error - dump directory is not writeable - giving up\n";
    `echo 'Problem(s) were encountered while trying to perform pgdumps' | mail -s "PROBLEM running pgdumps" $annoy`;
    exit(1);
}

# TODO - take version and clustername parameters, and only dump relevant cluster(s) if received.


my ($overallproblemreport,$problemreport) = (0,0);
my @clusters;
my $cluster;
$debug{'showcomment'} && print "============\n";
foreach $pgversion (sort (get_versions())) {
    @clusters = grep {get_cluster_start_conf($pgversion, $_) ne 'disabled'} get_version_clusters $pgversion;
    $debug{'showcomment'} && print "Dumping clusters in version $pgversion\n";

    foreach $cluster (sort @clusters) {
        $debug{'showcomment'} && print "Dumping databases in cluster $cluster\n";
        $problemreport = pgdump_cluster($pgversion, $cluster, $backupdir, $hanoinumber);
        $overallproblemreport ||= $problemreport;
    }
    if ($overallproblemreport) {
        print "Problem(s) encountered\n";
        `echo 'Problem(s) were encountered while trying to perform pgdumps' | mail -s "PROBLEM running pgdumps" $annoy`
    } else {
        if ($debug{'showcomment'}) {
            print "Overall success reported\n";
        }
    }
}
exit($overallproblemreport);

sub pgdump_cluster {
    my ($pgversion, $clustername, $dumpdir, $hanoinumber) = @_;
    my %info = cluster_info $pgversion, $clustername;
    if (!$info{'running'}) {
        print "Error - could not dump $pgversion $clustername - cluster not running\n";
        return 1;
    }

    # don't dump on slave
    unless (db_check_master($pgversion, $clustername)) {
        return 0; # this is an ok situation, not an error
    }

    my ($seconds, $minutes, $hours, $dom, $month, $year, @timearray) = localtime();
    my $clusterdumptime = sprintf "%4d-%02d-%02d-%02d%02d%02d", $year + 1900, $month + 1, $dom, $hours, $minutes, $seconds;
    $debug{'level'} && print $clusterdumptime . "\n";
    my $clusterdumpdir = "$dumpdir/pg-$pgversion-$clustername";
    my $currentdir = "$clusterdumpdir/current";
    if (! -e $currentdir ) {
        attempt("Making \"current\" dump directory", ("/bin/mkdir", "-p", "$currentdir"));
    }
    my $hanoidumpdir = "$clusterdumpdir/$clusterdumptime-hanoi-$hanoinumber";
    attempt("Deleting old hanoi$hanoinumber pgdump dir", ("/usr/bin/find", "$clusterdumpdir", "-depth", "-type", "d", "-regex", ".*-hanoi-$hanoinumber", "-print", "-exec", "rm", "-R", "-f", "{}", ";"));
    attempt("Making new hanoi$hanoinumber pgdump dir", ("/bin/mkdir", "-p", "$hanoidumpdir"));
 
    my @databases = get_cluster_databases($pgversion, $clustername);
    my ($dbname, $dbfilename, $dbdumppath, $dbdumptime, $cmd);
    my $dbcount = @databases;
    $debug{'showcomment'} && print "dumping $dbcount databases\n";
    my $first = 1;
    my ($dumpproblem, $overalldumpproblems) = (0,0);
    DB:
    foreach $dbname (@databases) {
        $overalldumpproblems ||= $dumpproblem;
        if (!$first) {
            $debug{'showcomment'} && print "====\n";
        } else {
            $first = 0;
        }
        if ($debug{'showcomment'}) {
            print $dbname . "\n";
        }
        foreach my $skip (@skipdb) {
            if ($dbname eq $skip) {
                $debug{'showcomment'} && print "Skipping\n";
                next DB;
            }
        }
        ($seconds, $minutes, $hours, $dom, $month, $year, @timearray) = localtime();
        $dbdumptime = sprintf "%4d-%02d-%02d-%02d%02d%02d", $year + 1900, $month + 1, $dom, $hours, $minutes, $seconds;
        $dbfilename = "pg-$dbname-$dbdumptime.pgdump";
        $dbdumppath = "$hanoidumpdir/$dbfilename"; 
        $dumpproblem = attempt ("Dumping to hanoi dump dir", ("/usr/bin/pg_dump", "--cluster", "$pgversion/$clustername", "--format=custom", "--file", "$dbdumppath", "$dbname"));
        my @cmd = ("/usr/bin/find", "$currentdir", "-regex", ".*pg-$dbname-.*\.pgdump", "-print", "-delete"); 
        $dumpproblem ||= attempt ("Deleting old 'current' pgdump from currentdir",  @cmd );
        $dumpproblem ||= attempt ("Hard linking new dump into current dir", ("/bin/ln", $dbdumppath, "$currentdir/$dbfilename"));
    }

    if ($overalldumpproblems) {
        $debug{'level'} && print "Problems dumping one or more databases - not running currentdir cleanup \n";
        return $overalldumpproblems;
    } else {
        local %debug = %debug;
        $debug{'showstdout'} = 1;
        return attempt("Deleting other old files from current dir", ("/usr/bin/find", "$currentdir", "-mtime", "+1", "-print", "-delete"));
    }
}


exit;


sub attempt {
    my ($comment, @cmd) = @_;
    if ($debug{'showcomment'}) {
        print $comment . "\n";
    }

    my ($stdout, $stderr, $result) = tap @cmd;
    #$result = $exit_code >> 8;
    if ($debug{'showcmd'}) {
        print "Command: " . join (' ', @cmd) . "\n";
    }
    local %debug = %debug;
    if ($result != 0) {
        if (! $debug{'level'}) {
            # Bad result & requested no output - return;
            return 1;
        }
        # There is at least some debug turned on
        if (!$debug{'showcomment'}) {
            # This hasn't been printed yet:
            print $comment . "\n";
        }
        # Turn on lots of debugging:
        my $key;
        my @keys = ('showcmd', 'showresult', 'showstdout', 'showstderr');
        foreach $key (@keys) {
            $debug{$key} = 1;
        }
    }
    if ($debug{'showcmd'}) {
        print "Command: " . join(' ', @cmd) . "\n";
    }
    if ($debug{'showresult'}) {
        print "Result: " . $result . "\n";
    }
    if ($debug{'showstdout'}) {
        print $stdout . "\n";
    }
    if ($debug{'showstderr'}) {
        print $stderr . "\n";
    }
    return $result;
}

# Generate an array of numbers
# Each number represents which copy to overwrite each dumpcycle such that:
# Copy 1 is kept for half as long as copy 2
# Copy 2 is kept for half as long as copy 3
# Copy N is kept for half as long as copy N+1
# The details and objectives behind this can be found on the wiki.
sub generate_hanoi {
    my $hanoi_size = $_[0];
    my @hanoi_array;
    my $i;
    if ($hanoi_size == 1) {
        @hanoi_array = (1);
        return @hanoi_array;
    }
    for ($i = $hanoi_size;$i >1; $i--) {
        push @hanoi_array, generate_hanoi($i - 1);
    }
    push @hanoi_array, $hanoi_size;
    return @hanoi_array;
}

# Determine which dump number we want to write to (and hence, which one we want to overwrite)
sub determinedumpnumber {
    ($backupcopies, $backupinterval, %debug) = @_;
    my $intervalssinceepoch;
    my @hanoi = generate_hanoi($backupcopies);
    my $arraylength = 2 ** ($backupcopies -1);
    my $tzoffset = tz_local_offset();

    # (Rounded off to the nearest int):
    $intervalssinceepoch = sprintf "%.0f", ((time() + $tzoffset)/$backupinterval);
    my $index = $intervalssinceepoch % $arraylength;
    if ($debug{'level'} != 0) {
        # Log the whole array to show where we're up to
        my $i = 0;
        my $hanoinumber;
        foreach $hanoinumber (@hanoi) {
            print " " . $hanoinumber;
            if ($i == $index) {
                print "*";
            }
            $i++;
        }
        print "\n";
    }
    return $hanoi[$index];
}

sub db_check_master {
    my ($version, $cluster) = @_;
    my $db = 'postgres';
    my %info = cluster_info($version, $cluster);
    my $port = $info{port};
    my $dsn = "DBI:Pg:dbname=$db;port=$port";

    my $dbh = DBI->connect( $dsn, undef, undef, {PrintError=>0, RaiseError=>0} );
    if (defined $dbh) {
        my $ans = $dbh->selectall_arrayref("SELECT pg_is_in_recovery()");
        if (defined $ans) {
            return ! $ans->[0][0];
        }
        else {
            # doesn't have that function, so must be old master
            return 1;
        }
    }
    else {
        if (DBI::errstr() eq 'FATAL:  the database system is starting up') {
            return 0;
        }
        else {
            die 'DB not running';
        }
    }
}
