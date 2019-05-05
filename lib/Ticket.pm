package Ticket;
use strict; use warnings;
use 5.010;
use Carp;
use Class::Load qw/try_load_class load_class/;
use Cwd;
use Data::Dump 'pp';
use Exporter 'import';
use List::MoreUtils qw/firstval/;
use MIME::Base64;
use Text::Unidecode;
use Try::Tiny;
use YAML::Syck;
use experimental qw/smartmatch/;
use JSON::XS;
our @EXPORT_OK = qw/cfg session_cfg ticket_out err verbose assert_branch build_branch get_issuekeys %EXIT/;

my %CFG;

our %EXIT = (
    GENERIC               => 1,
    EXTERNAL_SERVICE_DOWN => 39,
    HEADS_UP              => 44,
);

sub _config_file {
    (my $path = Cwd::realpath(__FILE__)) =~ s|lib/Ticket.pm|ticket.conf|;
    return $path;
}

sub _build_config {
    %CFG = (
        # Defaults
        user           => $ENV{USER},
        ticket_pattern => qr/([a-zA-Z0-9]+-\d+)/,
        remote         => 'origin',
        branch_length  => 88,
        verbose        => 1,
        'format'       => 'legacy',
    );
    my $config_file = _config_file();
    if (-e $config_file) {
        try {
            my $data = YAML::Syck::LoadFile($config_file);
            # Overwrite defaults with config
            for (keys %$data) {
                $CFG{$_} = $data->{$_};
                if (/host$/) {
                    #append / at the end
                    $CFG{$_} =~ s| [^/] \K $ |/|x;
                }
            }
        } catch {
            say STDERR "Problems parsing $config_file: $_";
            exit 1;
        };
    }

    # encoded pass takes precedence
    $CFG{pass} = decode_base64($CFG{pass64}) if $CFG{pass64};

    # If either pass or credentials are defined in config, they will be used instead of cookie mechanism
    # but pass takes precedence
    if ($CFG{pass}) {
        $CFG{credentials} = $CFG{user} .':'. $CFG{pass};
    }

    # These cannot be overwritten
    $CFG{branch_pattern} = sprintf '(\w+/%s[_-]\w+)', $CFG{ticket_pattern};
}

### Functions ###

my $loaded;
sub cfg {
    return @CFG{@_} if defined $loaded;
    _build_config();
    $loaded = 1;
    return @CFG{@_};
}

sub session_cfg {
    my ($k, $v) = @_;
    $CFG{$k} = $v;
}

sub err ($) { die ((ref $_[0] ? pp $_[0] : $_[0])."\n") }
sub verbose(@) { cfg('verbose') && say @_ }

my $tracker;
sub tracker {
    return $tracker if defined $tracker;

    my $class = cfg('tracker_class');
    if (! try_load_class($class)) {
        my $default_class = 'IssueTracker::Jira';
        warn "Cannot load class $class, defaulting to $default_class";
        load_class($class = $default_class);
    }
    return $tracker = $class->new;
}

my $dot_dir;
sub _dot_dir {
    return $dot_dir if defined $dot_dir;

    $dot_dir = $ENV{HOME} .'/.ticket';
    mkdir $dot_dir, 0700 unless -d $dot_dir;
    return $dot_dir;
}

my $issue_matches_branch;
# expects to be given an issue HASH, from IssueTracker::fetch or ::search
sub has_branch {
    my ($issue) = @_;
    croak "Given issue hadn't had its description field fetched!" unless exists $issue->{description};
    return 0 unless defined $issue->{description};

    if (not $issue_matches_branch) {
        my $branch_pattern = cfg('branch_pattern');
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
}

sub assert_branch {
    my ($key, $set_if_none, $custom_branch) = @_;

    my $branch;
    my $issue = tracker->fetch($key, qw/description issuetype summary/);
    if ($branch = has_branch($issue)) {
        return $branch;
    } elsif ($set_if_none) {
        $branch = $custom_branch || build_branch($issue);
        my $desc = sprintf "*branch*:{code}%s{code}\n%s", $branch, $issue->{description} // '';
        #tracker->update($key, description => {'=' => $desc});
        verbose "Prepended $key description with $branch";
    } else {
        croak "no branch in $key.";
    }
    return $branch;
}
sub build_branch {
    my ($issue_fields) = @_;
    my ($type, $key, $summary) = @{ $issue_fields }{qw/issuetype key summary/};

    my $prefix = {
        'Sub-task'       => 'task',
        'Tech Story'     => 'technical',
        'Technical Task' => 'technical',
        'Bug Fix'        => 'bug',
    }->{$type} // lc $type;

    $summary =~ s/&[^;]+;//g;       #strip html entities
    $summary =~ s/['"]//g;          #strip chars that provide no additional meaning
    $summary =~ s/\W+/_/g;          #replace not alphanumeric with _
    $summary = unidecode($summary); #latinize
    $summary =~ s/_{2,}/_/g;        #strip duplicate _
    $summary =~ s/^_|_$//g;         #strip border _

    my $branch = $prefix .'/'. $key .'_'. $summary;

    my $max_length = cfg('branch_length');
    return $branch if length $branch <= $max_length;

    my $is_cut_in_middle = substr $branch, $max_length, 1 ne '_';
    $branch = substr $branch, 0, $max_length;
    $branch =~ s/_[^_]{0,18}$// if $is_cut_in_middle;

    return $branch;
}

sub _service_cookie_from_url {
    my ($service) = $_[0] =~ m|//(\w+)|;
    return _dot_dir() .'/jar_'. $service;
}
sub clear_authorization_data {
    # Ignore cookies if credentials provided
    return if cfg('credentials');

    verbose 'Clearing cookie jar. You will have to provide password next time to create another.';
    unlink _service_cookie_from_url(@_);
}
sub get_authorization_data {
    my ($url) = @_;
    my $credentials = cfg('credentials');
    #FIXME this function should receive cfg key (i.e. 'ci_tool_host') instead of url
    if (ref $credentials) {
        for (keys %$credentials) {
            my $cfg_url = cfg($_);
            if ($url =~ /^$cfg_url/) {
                $credentials = $credentials->{$_};
                last;
            }
        }
    }
    # Ignore cookies if credentials provided
    return ('-u', $credentials) if $credentials and not ref $credentials;

    my $cookie = _service_cookie_from_url(@_);

    if (-r $cookie) {
        return ('-b', $cookie);
    } else {
        return ('-u', $credentials, '-c', $cookie);
    }
}

sub get_issuekeys {
    my @keys = API::Git::get_issuekeys_from_branch();
    @keys = API::Git::get_issuekeys_from_commit() unless @keys;

    croak 'No ticket could be determined.' unless @keys;

    return @keys;
}

sub manipulate_ticket {
    my ($key, $fields) = @_;

    my (@fetch, %update);

    for (@{ $fields }) {
        if (my ($name, $subname, $action, $value) = /^(\w+)\.?(\w*)([=+:\-])(.*)/) {
            if ($subname) {
                $value = {$subname => $value};
            }
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
};

sub out {
    return ref $_[0] ? pp $_[0] : $_[0]
}
sub ticket_out {
    my ($issue, @fields) = @_;

    if (cfg('format') eq 'json') {
        if ('HASH' eq ref $issue) {
            my %temp;
            @temp{@fields} = @{$issue}{@fields};
            say encode_json(\%temp);
        } else {
            my @issues;
            for (@$issue) {
                my %temp;
                @temp{@fields} = @{$_}{@fields};
                push @issues, \%temp;
            }
            say encode_json(\@issues);
        }
        return;
    }

    for my $is ('ARRAY' eq ref $issue ? @$issue : $issue) {
        if (@fields < 2) {
            say out($is->{$fields[0] // 'key'} // '');
        } elsif (@fields == 2 and 'key' ~~ \@fields) {
            say $is->{key} ."\t"
                . (out($is->{$fields[int('key' eq $fields[0])]}) // '');
        } else {
            say $is->{key};
            for (@fields) {
                if (defined $is->{$_}) {
                    say out($is->{$_});
                } else {
                    say '~';
                }
            }
        }
    }
}

1;
