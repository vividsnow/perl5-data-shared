package Data::Shared::Adapter::Sync;
use strict;
use warnings;
use Carp ();

our $VERSION = '0.01';

our @CARP_NOT = qw(Data::Shared);

sub make_verb { return undef }
sub make_bound { return undef }
sub make_bound_push { return undef }
sub make_bound_pop { return undef }
sub make_push { return undef }
sub make_pop  { return undef }

sub perform {
    my ($class, $verb, $handle, $entry, $rest, @args) = @_;
    Carp::croak("operation '$verb' is not supported for sync/timing mount '$entry->{key}'; use shared_call with the native method name");
}

sub perform_push { Carp::croak("push is not supported for sync/timing mounts (use shared_call)") }
sub perform_pop  { Carp::croak("pop is not supported for sync/timing mounts (use shared_call)") }

1;

__END__

=head1 NAME

Data::Shared::Adapter::Sync - Internal adapter for sync/timing mounts (Data::Shared)

=head1 DESCRIPTION

Internal to L<Data::Shared>; not a public API. Sync and timing
mounts (Sync primitives, TimingWheel, HierTimingWheel, ReqRep)
support no generic verbs; every operation goes through
C<shared_call> with the native method name.

=cut
