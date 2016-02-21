package API::Git;
use strict;use warnings;
use IPC::System::Simple qw/capture system/;
use FindBin;
use lib "$FindBin::RealBin/lib";
use Ticket qw/cfg err/;
use Exporter 'import';

our @EXPORT_OK = qw/
    cd_to_repo_root
    checkout_to_branch
    get_current_branch
    get_issuekeys_from_branch
    get_issuekeys_from_commit
    get_rev
    get_tag get_previous_tag
    tag_rev
/;

my $DELIMITER = 'DeliMdElIM';
my ($REMOTE, $TICKET_PATTERN) = cfg qw/remote ticket_pattern/;

sub _match_against_ticket_pattern {#{{{
    my @keys = $_[0] =~ /$TICKET_PATTERN/g;
    return @keys;
}#}}}

sub cd_to_repo_root {#{{{
    chomp(my $root_dir = capture(qw/git rev-parse --show-toplevel/));
    chdir $root_dir;
}#}}}

sub checkout_to_branch {#{{{
    my ($branch, $start_point) = @_;

    my $remote_branch = $branch !~ /^$REMOTE/
        ? $REMOTE.'/'. $branch
        : $branch;

    my $branch_exists = length capture(qw/git branch --list --remote/, $remote_branch);

    my @checkout = qw/git checkout/;
    push @checkout, '-b' unless $branch_exists;
    push @checkout, $branch;
    # if branch already exist, providing start_point will break
    # it's expected because user needs to know that fact and reason behind it)
    if ($start_point) {
        push @checkout, $start_point;

        # prevent tracking start point, but only if creating new branch
        # so that we can benefit from smart behavior of git checkout branch when origin/branch is present (when tracking occurs and is welcomed)
        # and at the same time prevent users from mindlessly push to start_point, which is rarely what we want (because it was tracked by default)
        push @checkout, '--no-track' unless $branch_exists;
    }

    system @checkout;
}#}}}

sub get_current_branch {#{{{
    chomp(my $branch = capture(qw/git rev-parse --abbrev-ref HEAD/));
    return $branch;
}#}}}

sub get_issuekeys_from_branch {#{{{
    return _match_against_ticket_pattern( get_current_branch );
}#}}}

sub get_issuekeys_from_commit {#{{{
    my ($rev) = @_;

    my $format = join $DELIMITER, qw/%B %an %h/;

    my @log = (qw/git log -1/, "--format=$format");
    push @log, defined $rev
        ? $rev
        : '--no-merges';

    my ($message, $author, $short_rev) = split $DELIMITER, capture(@log);

    my @keys = _match_against_ticket_pattern($message);
    if (! @keys) {
        $rev //= $short_rev;
        chomp $rev;
        err "No tickets found in $rev authored by $author.";
    }
    return @keys;
}#}}}

sub get_rev { chomp( my $rev = capture(qw/git rev-parse/, $_[0]) ); $rev }

sub get_tag {#{{{
    my ($branch) = @_;
    $branch //= 'HEAD';
    chomp(my $tag = capture(qw/git describe --abbrev=0/, $branch));
    return $tag;
}#}}}

sub get_previous_tag {#{{{
    my ($tag) = @_;

    $tag //= get_tag;
    return get_tag($tag .'^');
}#}}}

sub tag_rev {#{{{
    my ($version, $revision) = @_;

    my @cmd = (qw/git tag -a -m/, $version, $version);
    push @cmd, $revision if $revision;
    system @cmd;
}#}}}


1;
