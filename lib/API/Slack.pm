package API::Slack;
use strict;use warnings;
use IPC::System::Simple qw/capture/;
use JSON::XS;
use Term::ANSIColor;
use Ticket qw/cfg/;
use Carp;

sub post {
    my %params = @_;

    my $endpoint = cfg('slack_url');
    croak 'No "slack_url" in config' unless $endpoint;

    my $response = capture (
        qw/curl --silent --show-error -X POST --data-urlencode/,
        'payload='. encode_json(\%params),
        $endpoint,
    );
    croak $response if $response ne 'ok';
}

sub format_url {
    my ($url, $name) = @_;
    return '<'. $url .'|'. $name .'>';
}

sub chat {
    my ($channel, $msg, %opts) = @_;

    my $tracker = Ticket::tracker;
    my $ticket_regex = cfg('ticket_pattern');

    $msg = Term::ANSIColor::colorstrip($msg);

    if ($opts{link_tickets} // 1) {
        # replace every ticket with its link
        # if it's already a link, just format it to fold it to ticket
        my $url = $tracker->issue_url('');
        $msg =~ s/(?:$url)?$ticket_regex/format_url($url.$1, $1)/ge;
    }

    post(channel => $channel, text => $msg, link_names => 1, %opts);
}

sub attachments_from_keys {
    my (@keys) = @_;

    local $" = ',';
    my $t = Ticket::tracker;
    return [map {
        {
            text => $_->{summary},
            title => format_url($t->issue_url($_->{key}), $_->{key})
        }
    } $t->search(query => "KEY IN (@keys)", fields => [qw/key summary/])];
}

1;
