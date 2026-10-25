package Data::Shared::Adapter;
use strict;
use warnings;
use Carp ();

our $VERSION = '0.01';

our @CARP_NOT = qw(Data::Shared);

# The adapter interface, stated once. The facade calls all six makers without
# asking whether an adapter has them, and reads undef as "this verb is not
# available here, take the slow path". A default adapter therefore supports
# nothing, and each adapter below overrides only what its family can do, which
# is why Sync needs no body at all.
sub make_verb       { return undef }
sub make_bound      { return undef }
sub make_push       { return undef }
sub make_pop        { return undef }
sub make_bound_push { return undef }
sub make_bound_pop  { return undef }

# The facade calls these whenever the matching maker returned undef, so they
# are part of the interface rather than a hypothesis. Every adapter overrides
# them with its family's wording; without a default here, one that forgot
# would raise "Can't locate object method" instead of saying what it cannot do.
sub perform_push { Carp::croak("Data::Shared: push is not supported for this mount (use shared_call)") }
sub perform_pop  { Carp::croak("Data::Shared: pop is not supported for this mount (use shared_call)") }

# The slow path: build the verb and call it, or say it does not exist. Four
# adapters wrote these three steps out, two of them character for character;
# only the wording that points at a better route differs, so that is what an
# adapter overrides. Sync has no verbs at all and keeps its own.
sub perform {
    my ($class, $verb, $handle, $entry, $rest, @args) = @_;
    my $code = $class->make_verb($verb, $handle, $entry);
    Carp::croak($class->_unsupported_verb($verb, $entry)) unless $code;
    return $code->($rest, @args);
}

sub _unsupported_verb {
    my ($class, $verb, $entry) = @_;
    return "Data::Shared: operation '$verb' is not supported for $entry->{key} (use shared_call)";
}

# One lookup, after three spellings of it had drifted apart: a missing verb
# table and a missing verb answer the same way.
sub _spec {
    my ($entry, $verb) = @_;
    my $verbs = $entry->{verbs} or return undef;
    return $verbs->{$verb};
}

# The message every adapter built from the same template in two places each.
sub _unsupported {
    my ($entry, $handle, $spec) = @_;
    return "Data::Shared: $entry->{key}: " . ref($handle) . " does not support '$spec'"
        . " (use shared_call for operations outside the generic verbs)";
}

1;

__END__

=head1 NAME

Data::Shared::Adapter - Internal base for the per-family adapters (Data::Shared)

=head1 DESCRIPTION

Internal to L<Data::Shared>; not a public API. Holds the adapter interface's
defaults, so each adapter states only what its family supports, and the verb
lookup and unsupported-verb message they share.

=cut
