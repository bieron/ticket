package IssueTracker::Jira;# {{{
use strict; use warnings;
use 5.010;
use Carp;
use List::MoreUtils qw/firstval/;
use Role::Tiny::With;

use API::Atlassian;
use Ticket qw/cfg err verbose/;

with 'IssueTracker';# }}}

# OO used solely for inheritance / overloading
sub new { bless \$_[0], $_[0] }

### read only class properties getters:

sub processor {#{{{
    my %processor = (
        log => \&log_work,
        assignee => sub {
            my ($key, $assignee) = @_;
            $assignee = cfg('jira_username')//cfg('user') if $assignee eq '@';
            # unassign if $assignee is false
            undef $assignee unless $assignee;
            API::Atlassian::assign_to_issue($key, $assignee);
        },
        comment => \&API::Atlassian::comment_issue,
        (map {$_ => \&perform_transition} qw/status workflow action/),
        file => \&API::Atlassian::attach_file_to_issue,
        fixVersions => sub {
            my ($key, @versions) = @_;
            my ($project) = split '-', $key;
            assert_version($project, $_) for @versions;
            API::Atlassian::set_issue_fields($key, {fields => {
                fixVersions => API::Atlassian::in_complex_list(@versions)
            }});
        },
    );
    return wantarray ? %processor : \%processor;
}#}}}

sub composer {#{{{
    my %in = (
        #parent => sub { {key => $_[0]} }, #JIRA REST API doesn't support updating sub-task parent
        (map {$_ => \&API::Atlassian::in_complex} qw/status priority resolution issuetype assignee reporter/),
        (map {$_ => \&API::Atlassian::in_complex_list} qw/components/),
        labels => sub { [split ',', $_[0]] },
    );
    return wantarray ? %in : \%in;
}#}}}

sub decomposer {#{{{
    my %out = (
        parent => sub { join ' ', $_[0]{key}, $_[0]{fields}{summary} },
        (map {$_ => \&API::Atlassian::out_complex} qw/status priority resolution issuetype assignee reporter/),
        (map {$_ => \&API::Atlassian::out_complex_list} qw/components fixVersions/),
        issuelinks => sub {
            my @relations;
            for (@{ $_[0] }) {
                my $rel = exists $_->{inwardIssue} ? 'inward' : 'outward';
                my $issue = $_->{$rel.'Issue'};

                push @relations, join "\t", $_->{type}{$rel}, $issue->{key}, $issue->{fields}{summary};
#                push @{ $relation{$_->{type}{$rel}} }, [
#                    $issue->{key}, $issue->{fields}{summary}
#                ];
            }
            return join "\n", @relations;
        },
        labels => sub { join ',', @{$_[0] // []} },
        summary => sub {$_[0]},
        timetracking => sub {
            my %log = %{$_[0]};
            for (keys %log) {
                delete $log{$_} if /Seconds$/;
            }
            return \%log;
        },
    );
    $out{subtasks} = sub {
        my @subtasks;
        for my $task (@{$_[0]}) {
            push @subtasks, join "\t",
                $task->{key},
                (map {$out{$_}->($task->{fields}{$_})} qw/status priority summary/);
#            push @subtasks, {
#                key => $task->{key},
#                (map {$_ => $out{$_}->($task->{fields}{$_})} qw/status priority summary/)
#            };
        }
        return join "\n", @subtasks;
    };
    return wantarray ? %out : \%out;
}#}}}

sub translator {#{{{
    return {
        fixversion => 'fixVersions',
        (map {$_ => 'log'} qw/work worklog/),
        (map {$_ => $_ . 's'} qw/fixVersion label component/),
        time => 'timetracking',
        estimate => 'timetracking.originalEstimate',
        remaining => 'timetracking.remainingEstimate',
    };
}#}}}

### class methods:

sub translate {#{{{
    my ($self, @fields) = @_;
    my %trans = %{ $self->translator };
    return {
        map {$_ => $trans{$_}//$_} @fields
    };
}#}}}

sub fetch {#{{{
    my ($self, $key, @fields) = @_;

    my %trans = %{ $self->translate(@fields) };

    my %struct = %{
        API::Atlassian::get_issue_fields($key, [@trans{@fields}])
    };

    my %output = (key => $key);
    %trans = reverse %trans;
    my %decomp = $self->decomposer;
    for my $name (keys %struct) {
        my $value = exists $decomp{$name}
            ? $decomp{$name}->($struct{$name})
            : $struct{$name};

        $output{ $trans{$name} } = $value;
    }

    return \%output;
}#}}}

# Transforms structure into Jira API payload and
# updates issue if $key given or creates new one if not
sub _upsert {#{{{
    my ($self, $outer, $key) = @_;

    my %comp  = $self->composer;
    my %proc  = $self->processor;
    my %fields = %{$outer};
    my %trans = %{ $self->translate(keys %fields) };

    my %action_map = (
        '+' => 'add',
        '-' => 'remove',
        '=' => 'set',
        ':' => 'edit',
    );
    my (%inner, %processable);

    # compose user friendly fields into jira compliant structure
    FIELD:
    for my $name (keys %fields) {
        my $inner_name = $trans{$name};
        if (exists $proc{$inner_name}) {
            if (keys %{$fields{$name}} > 1 || ! exists $fields{$name}{'='}) {
                err "Use '$name=value' to change $name";
            }
            # even though they can be normally set on creation, some fields are handled differently for existing issues
            # especially custom fields that are just references to resources defined elsewhere need to ensure that the reference points to existing resource or create it)
            # so we defer processing them until after create (or update, for consistency)
            $processable{$inner_name} = $fields{$name}{'='};
            next FIELD;
        }

        ACTION:
        for (keys %{ $fields{$name} }) {
            my $value = $fields{$name}{$_};
            if (exists $comp{$inner_name}) {
                $value = $comp{$inner_name}->($value);
            }

            #set action - use simpler syntax (which is incompatible with add/remove)
            if ($_ eq '=') {
                $inner{fields}{$inner_name} = $value;
                next ACTION;
            }

            #add or remove action - complex syntax
            my $action = $action_map{$_};

            push @{ $inner{update}{$inner_name} }, ref $value eq 'ARRAY'
                ? map { { $action => $_ } } @{$value}
                : { $action => $value };
        }
    }

    # upsert payload
    if ($key) {
        # %inner might be empty if all $outer %fields are %processable
        API::Atlassian::set_issue_fields($key, \%inner) if scalar keys %inner;
    } else {
        $key = API::Atlassian::create_issue(\%inner);
    }

    # process special fields
    # It would be easy to support =/+/- modes in processors, by sending mode as another parameter
    # However it makes code more complex and there are more usability pitfalls than benefits
    for (sort keys %processable) {
        $proc{$_}->($key, $processable{$_});
    }

    return $key;
}#}}}

sub update {#{{{
    my ($self, $key, %fields) = @_;
    $self->_upsert(\%fields, $key);
    return;
}#}}}

sub create {#{{{
    my ($self, %fields) = @_;
    return $self->_upsert(\%fields);
}#}}}

sub search {#{{{
    my ($self, %param) = @_;
    croak q/'query' parameter required!/ unless $param{query};

    my %trans = %{ $self->translate(@{ $param{fields} }) };
    delete $trans{key};

    my $fields = [$param{fields}
        ? values %trans
        : 'key'
    ];

    my %api = (
        jql         => $param{query},
        maxResults  => $param{limit} // -1,
        fields      => $fields,
#        startAt => $param{from},
    );

    %trans = reverse %trans;
    my %decomp  = $self->decomposer;
    my @issues;
    for (@{ API::Atlassian::search_for_issues(%api) }) {
        #there will be no fields if only key was requested
        my %struct = %{ $_->{fields} // {} };

        my %output = (key => $_->{key});
        for my $name (keys %trans) {
            my $value = exists $decomp{$name}
                ? $decomp{$name}->($struct{$name})
                : $struct{$name};

            $output{ $trans{$name} } = $value;
        }
        push @issues, \%output;
    }
    return @issues;
}#}}}

sub log_work {#{{{
    my ($key, $value) = _remove_self(@_);
    API::Atlassian::log_work_for_issue($key, split '@', $value);
    return;
}#}}}

sub perform_transition {#{{{
    my ($key, $actions_csv) = _remove_self(@_);

    my $skip_invalid = $actions_csv =~ s/!$//;

    for my $transition (split ',', $actions_csv) {
        my ($provided_name, $resolution) = split ':', $transition;

        my @available = @{ API::Atlassian::get_issue_transitions($key) };

        if (not @available) {
            err "No actions possible for $key.";
        }

        my $transition = firstval {$_->{name} =~ /$provided_name/i} @available;
        if (not defined $transition) {
            next if $skip_invalid;

            my $possibles = join '', map {
                "\n- $_->{name} \t(-> $_->{to}{name})"
            } @available;

            err "Invalid action '$provided_name'.\nPossible actions for $key:$possibles";
        }
        API::Atlassian::transition_issue($key, $transition->{id}, $resolution);
        verbose "Performed '$transition->{name}' on $key (now $transition->{to}{name}).";
    }
    return;
}#}}}

sub issue_url {#{{{
    my ($key) = _remove_self(@_);
    return cfg('tracker_host') .'browse/'. $key;
}#}}}

my %version_name_2_id;
sub assert_version {#{{{
    my ($project, $name) = _remove_self(@_);

    if (exists $version_name_2_id{ $project }{ $name }) {
        return $version_name_2_id{ $project }{ $name }
    }

    for (@{ API::Atlassian::get_versions($project) }) {
        if ($_->{name} eq $name) {
            #version already exists
            return $version_name_2_id{ $project }{ $name } = $_->{id};
        }
    }

    my $id = API::Atlassian::create_version(project => $project, name => $name);
    verbose "Created version '$name' in project $project";
    return $version_name_2_id{ $project }{ $name } = $id;
}#}}}

1;
