package Ticket;#{{{
use strict; use warnings;
use 5.010;
use Carp;
use Class::Load 'load_class';
use Config::Simple;
use Data::Dump 'pp';
use Exporter 'import';
use autodie ':filesys';
use List::MoreUtils qw/firstval none/;
use Term::ReadKey;
use Text::Unidecode;#}}}
our @EXPORT_OK = qw/cfg ticket_out err verbose assert_branch build_branch get_issuekeys/;

my $dot_dir = $ENV{HOME} .'/.ticket';
mkdir $dot_dir, 0700 unless -d $dot_dir;
my %CFG;

{ #{{{ initalize config
    %CFG = (
        # Defaults
        user           => $ENV{USER},
        tracker_class  => 'IssueTracker::Jira',
        ticket_pattern => qr/([a-zA-Z]+-\d+)/,
        remote         => 'origin',
        branch_length  => 88,
    );
    my $config_file = $dot_dir .'/config';
    if (-e $config_file) {
        Config::Simple->import_from($config_file, \my %file);
        # Overwrite defaults with config
        for (keys %file) {
            (my $key = $_) =~ s/^common\.//;
            $CFG{$key} = $file{$_};
            if (/host$/) {
                #append / at the end
                $CFG{$key} =~ s| [^/] \K $ |/|x;
            }
        }
    }

    # If either pass or credentials are defined in config, they will be used instead of cookie mechanism
    # but pass takes precedence
    if ($CFG{pass}) {
        $CFG{credentials} = $CFG{user} .':'. $CFG{pass};
    }

    # These cannot be overwritten
    $CFG{dot_dir} = $dot_dir;
    $CFG{branch_pattern} = sprintf '(\w+/%s[_-]\w+)', $CFG{ticket_pattern};
}#}}}

### Functions ###

sub cfg (@) { @CFG{ @_ } }
sub err ($) { croak ref $_[0] ? pp $_[0] : $_[0] }
sub verbose { $CFG{verbose} && say @_ }

my $tracker;
sub tracker {#{{{
    return $tracker if defined $tracker;

    my $class = cfg 'tracker_class';
    load_class($class);
    return $tracker = $class->new;
}#}}}

my $issue_matches_branch;
sub has_branch {#{{{
    my ($issue) = @_;
    croak "Given issue hadn't had its description field fetched!" unless exists $issue->{description};
    return 0 unless defined $issue->{description};

    if (not $issue_matches_branch) {
        my $branch_pattern = cfg 'branch_pattern';
        $issue_matches_branch = qr/
            branch [:\W]*? (?:
                {code} \s* $branch_pattern \s* {code}
                | \s* $branch_pattern \s*
            )
        /ix;
        $issue_matches_branch = qr/(?:
            {code} \W*? $issue_matches_branch \W*? {code}
            | $issue_matches_branch
        )/x;
    }

    return firstval {$_} $issue->{description} =~ $issue_matches_branch;
}#}}}

sub assert_branch {#{{{
    my ($key, $set_if_none, $custom_branch) = @_;

    my $branch;
    my $issue = tracker->fetch($key, qw/description issuetype summary/);
    if ($branch = has_branch($issue)) {
        return $branch;
    } elsif ($set_if_none) {
        $branch = $custom_branch || build_branch($issue);
        my $desc = sprintf "*branch*:{code}%s{code}\n%s", $branch, $issue->{description} // '';
        tracker->update($key, description => {'=' => $desc});
        verbose "Prepended $key description with $branch";
    } else {
        err "no branch in $key.";
    }
    return $branch;
}#}}}
sub build_branch {#{{{
    my ($issue_fields) = @_;
    my ($type, $key, $summary) = @{ $issue_fields }{qw/issuetype key summary/};

    my $prefix = {
        'Sub-task'   => 'task',
        'Tech Story' => 'technical',
    }->{$type} // lc $type;

    $summary =~ s/&[^;]+;//g;       #strip html entities
    $summary =~ s/['"]//g;          #strip chars that provide no additional meaning
    $summary =~ s/\W+/_/g;          #replace not alphanumeric with _
    $summary = unidecode($summary); #latinize
    $summary =~ s/_{2,}/_/g;        #strip duplicate _
    $summary =~ s/^_|_$//g;         #strip border _

    my $branch = $prefix .'/'. $key .'_'. $summary;

    my $max_length = cfg 'branch_length';
    return $branch if length $branch <= $max_length;

    my $is_cut_in_middle = substr $branch, $max_length, 1 ne '_';
    $branch = substr $branch, 0, $max_length;
    $branch =~ s/_[^_]{0,18}$// if $is_cut_in_middle;

    return $branch;
}#}}}

sub _service_cookie_from_url {#{{{
    my ($service) = $_[0] =~ m|//(\w+)|;
    return $dot_dir .'/jar_'. $service;
}#}}}
sub clear_authorization_data {#{{{
    # Ignore cookies if credentials provided
    return if $CFG{credentials};

    verbose 'Clearing cookie jar. You will have to provide password next time to create another.';
    unlink _service_cookie_from_url(@_);
}#}}}
sub get_authorization_data {#{{{
    # Ignore cookies if credentials provided
    return ('-u', $CFG{credentials}) if $CFG{credentials};

    my $cookie = _service_cookie_from_url(@_);

    if (-r $cookie) {
        return ('-b', $cookie);
    } else {
        return ('-u', $CFG{user}, '-c', $cookie);
    }
}#}}}

sub get_issuekeys {#{{{
    my @keys = API::Git::get_issuekeys_from_branch();
    @keys = API::Git::get_issuekeys_from_commit() unless @keys;

    err 'No ticket could be determined.' unless @keys;

    return @keys;
}#}}}

sub manipulate_ticket {#{{{
    my ($key, $fields) = @_;

    my (@fetch, %update);

    for (@{ $fields }) {
        if (my ($name, $action, $value) = /(\w+)([=+-])(.*)/) {
            $update{ $name }{ $action } = $value;
        } else {
            push @fetch, split ',', $_;
        }
    }

    if (scalar keys %update) {
        tracker->update($key, %update);
    }
    if (@fetch) {
        #FIXME ticket script "out()s" the ticket based on $O{field}. It's set here to fetched fields only to do not display "field=value   ..."
        #eventually, it would need to be fixed so that either the whole returned structure could be "out()ed" without tampering,
        #or the returned data contained information on how to do that
        #return (tracker->fetch($key, @fetch), \@fetch);
        $fields = \@fetch;
        return tracker->fetch($key, @fetch);
    }
};#}}}

sub out ($) {#{{{
    return unless defined $_[0];
    say ref $_[0] ? pp $_[0] : $_[0]
}#}}}
sub ticket_out ($;@) {#{{{
    my ($issue, @fields) = @_;

    if (not @fields) {
        say $issue->{key};
    }
    elsif (@fields == 1) {
        out $issue->{$fields[0]};
    } else {
        say $issue->{key};
        for (@fields) {
            print "\t$_\t";
            if (defined $issue->{$_}) {
                out $issue->{$_};
            } else {
                print '~';
            }
        }
        print "\n";
    }
}#}}}

1;
