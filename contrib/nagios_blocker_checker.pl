#!/usr/bin/perl

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/..";
use lib "$Bin/../lib";

use Bugzilla;
use Bugzilla::Constants;
use Bugzilla::Product;
use Bugzilla::User;
use Getopt::Long;

Bugzilla->usage_mode(USAGE_MODE_CMDLINE);


my $config = {
    # filter by assignee, product or component
    assignee        => '',
    product         => '',
    component       => '',
    unassigned      => 'nobody@mozilla.org',
    # severities
    severity        => 'major,critical,blocker',
    # time in hours to wait before paging/warning
    major_alarm     => 24,
    major_warn      => 20,
    critical_alarm  => 8,
    critical_warn   => 5,
    blocker_alarm   => 0,
    blocker_warn    => 0,
};

my $usage = <<EOF;
FILTERS

  the filter determines which bugs to check, either by assignee, product or the
  product's component. For backward compatibility, if just an email address is
  provided, it will be used as the assignee.

  --assignee <email>    filter bugs by assignee
  --product <name>      filter bugs by product name
  --component <name>    filter bugs by product's component name
  --unassigned <email>  set the unassigned user (default: $config->{unassigned})

SEVERITIES

  by default alerts and warnings will be generated for 'major', 'critical', and
  'blocker' bugs.  you can alter this list with the 'severity' switch.

  --severity <major|critical|blocker>[,..]

TIMING

  time in hours to wait before paging or warning

  --major_alarm <hours> (default: $config->{major_alarm})
  --major_warn  <hours> (default: $config->{major_warn})
  --critical_alarm <hours> (default: $config->{critical_alarm})
  --critical_warn  <hours> (default: $config->{critical_warn})
  --blocker_alarm <hours> (default: $config->{blocker_alarm})
  --blocker_warn  <hours> (default: $config->{blocker_warn})

EXAMPLES

  nagios_blocker_checker.pl --assignee server-ops\@mozilla-org.bugs
  nagios_blocker_checker.pl server-ops\@mozilla-org.bugs
  nagios_blocker_checker.pl --product 'mozilla developer network' --severity blocker
EOF

die($usage) unless GetOptions(
    'assignee=s'        => \$config->{assignee},
    'product=s'         => \$config->{product},
    'component=s'       => \$config->{component},
    'severity=s'        => \$config->{severity},
    'major_alarm=i'     => \$config->{major_alarm},
    'major_warn=i'      => \$config->{major_warn},
    'critical_alarm=i'  => \$config->{critical_alarm},
    'critical_warn=i'   => \$config->{critical_warn},
    'blocker_alarm=i'   => \$config->{blocker_alarm},
    'blocker_warn=i'    => \$config->{blocker_warn},
    'help|?'            => \$config->{help},
);
$config->{assignee} = $ARGV[0] if !$config->{assignee} && @ARGV;
die $usage if
    $config->{help}
    || !($config->{assignee} || $config->{product})
    || ($config->{assignee} && $config->{product})
    || ($config->{component} && !$config->{product})
    || !$config->{severity};

#

use constant NAGIOS_OK          => 0;
use constant NAGIOS_WARNING     => 1;
use constant NAGIOS_CRITICAL    => 2;
use constant NAGIOS_NAMES       => [qw( OK WARNING CRITICAL )];

my $dbh = Bugzilla->switch_to_shadow_db;
my($where, @values, $severity);

if ($config->{assignee}) {
    $where = 'bugs.assigned_to = ?';
    push @values, Bugzilla::User->check({ name => $config->{assignee} })->id;
} elsif ($config->{component}) {
    $where = 'bugs.product_id = ? AND bugs.component_id = ? AND bugs.assigned_to = ?';
    my $product = Bugzilla::Product->check({ name => $config->{product} });
    push @values, $product->id;
    push @values, Bugzilla::Component->check({ product => $product, name => $config->{component} })->id;
    push @values, Bugzilla::User->check({ name => $config->{unassigned} })->id;
} else {
    $where = 'bugs.product_id = ? AND bugs.assigned_to = ?';
    push @values, Bugzilla::Product->check({ name => $config->{product} })->id;
    push @values, Bugzilla::User->check({ name => $config->{unassigned} })->id;
}

$severity = '(' . join(',', map { $dbh->quote($_) } split(/,/, $config->{severity})) . ')';

my $sql = <<EOF;
    SELECT bug_id, bug_severity, UNIX_TIMESTAMP(bugs.creation_ts) AS ts
      FROM bugs
     WHERE $where
           AND COALESCE(resolution, '') = ''
           AND bug_severity IN $severity
EOF

my $bugs = {
    'major'     => [],
    'critical'  => [],
    'blocker'   => [],
};
my $current_state = NAGIOS_OK;
my $current_time = time;

foreach my $bug (@{ $dbh->selectall_arrayref($sql, { Slice => {} }, @values) }) {
    my $severity = $bug->{bug_severity};
    my $age = ($current_time - $bug->{ts}) / 3600;

    if ($age > $config->{"${severity}_alarm"}) {
        $current_state = NAGIOS_CRITICAL;
        push @{$bugs->{$severity}}, $bug->{bug_id};

    } elsif ($age > $config->{"${severity}_warn"}) {
        if ($current_state < NAGIOS_WARNING) {
            $current_state = NAGIOS_WARNING;
        }
        push @{$bugs->{$severity}}, $bug->{bug_id};

    }
}

print "bugs " . NAGIOS_NAMES->[$current_state] . ": ";
if ($current_state == NAGIOS_OK) {
    print "No $config->{severity} bugs found."
}
foreach my $severity (qw( blocker critical major )) {
    my $list = $bugs->{$severity};
    if (@$list) {
        printf "%s %s bug(s) found https://bugzil.la/" . join(',', @$list) . " ", scalar(@$list), $severity;
    }
}
print "\n";

exit $current_state;
