package IssueTracker;
use strict; use warnings;
use Role::Tiny;
use Ticket 'cfg';

requires $_ for qw/
    fetch update create search
/;

#allows subs to called OO $object->sub and static PACKAGE::sub
#also doesn't break overloading
sub _remove_self {#{{{
    if (Scalar::Util::blessed $_[0] && $_[0]->isa(scalar caller)) {
        shift @_;
    }
    return @_;
}#}}}

sub resolve_user {
  my ($self, $user) = @_;
  if ($user eq '@') {
    $user = cfg('tracker_account_id');
    die 'Cannot resolve "@" when conf is missing "tracker_account_id"' unless $user;
    return $user;
  }
}

1;
