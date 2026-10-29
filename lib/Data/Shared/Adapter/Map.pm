package Data::Shared::Adapter::Map;
use strict;
use warnings;
use Carp ();
# The argument guards live there, and an adapter is reachable on its own: the
# facade had always loaded it first, so calling into it was a latent die.
use Data::Shared::Registry ();

our $VERSION = '0.01';

# Path and verb croaks here are the caller's mistake, so Carp must not stop at
# the facade frame that dispatched into this adapter.
our @CARP_NOT = qw(Data::Shared);

sub _key {
    my ($entry, $rest, $verb) = @_;
    Carp::croak("path too short: mount has no key") unless @$rest;
    return join('/', @$rest) if $entry->{key_join};
    # Taking $rest->[0] and dropping the rest addressed a record the path did
    # not name, and coerced a non-numeric leftover on integer-keyed mounts.
    Carp::croak("path too long: $entry->{key} takes one key component")
        if @$rest > 1;
    # An integer-addressed mount numified a non-integer key to element 0, so a
    # garbage key read, overwrote or cleared it. Checked here, where a bound
    # closure resolves its key once, rather than per call. exists is exempt:
    # it is documented to answer 1 or 0 for any path, and its own verb
    # already refuses the shape.
    Data::Shared::Registry::_assert_index($entry->{key}, $rest->[0])
        if $entry->{key_int} && (!defined $verb || $verb ne 'exists');
    return $rest->[0];
}

sub make_verb {
    my ($class, $verb, $handle, $entry) = @_;
    my $spec = $entry->{verbs}{$verb};
    return undef unless defined $spec;
    if (ref $spec eq 'CODE') {
        return sub { my ($rest, @a) = @_; return $spec->($handle, _key($entry, $rest, $verb), @a) };
    }
    my $method = $handle->can($spec);
    if (!$method) {
        my $msg = "$entry->{key}: " . ref($handle) . " does not support '$spec'"
            . " (use shared_call for operations outside the generic verbs)";
        return sub { Carp::croak($msg) };
    }
    if ($verb eq 'incr') {
        my $by = $handle->can('incr_by');
        return sub {
            my ($rest, @a) = @_;
            Data::Shared::Registry::_assert_delta($entry->{key}, @a);
            my $key = _key($entry, $rest, $verb);
            return $handle->$by($key, $a[0]) if @a && $by;
            return $handle->$method($key, @a);
        };
    }
    return sub { my ($rest, @a) = @_; return $handle->$method(_key($entry, $rest, $verb), @a) };
}


sub make_bound {
    my ($class, $verb, $handle, $entry, $rest) = @_;
    my $spec = $entry->{verbs}{$verb};
    return undef unless defined $spec;
    my $key = _key($entry, $rest, $verb);
    if (ref $spec eq 'CODE') {
        return sub { my @a = @_; return $spec->($handle, $key, @a) };
    }
    my $method = $handle->can($spec);
    if (!$method) {
        my $msg = "$entry->{key}: " . ref($handle) . " does not support '$spec'"
            . " (use shared_call for operations outside the generic verbs)";
        return sub { Carp::croak($msg) };
    }
    if ($verb eq 'incr') {
        my $by = $handle->can('incr_by');
        return sub {
            my @a = @_;
            Data::Shared::Registry::_assert_delta($entry->{key}, @a);
            return $handle->$by($key, $a[0]) if @a && $by;
            return $handle->$method($key, @a);
        };
    }
    return sub { my @a = @_; return $handle->$method($key, @a) };
}

sub perform {
    my ($class, $verb, $handle, $entry, $rest, @args) = @_;
    my $code = $class->make_verb($verb, $handle, $entry);
    Carp::croak("operation '$verb' is not supported for $entry->{key} (use shared_call)")
        unless $code;
    return $code->($rest, @args);
}

sub make_push { return undef }
sub make_bound_push { return undef }
sub make_bound_pop { return undef }
sub make_pop  { return undef }
sub perform_push { Carp::croak("push is not supported for map mounts (use shared_set/shared_call)") }
sub perform_pop  { Carp::croak("pop is not supported for map mounts (use shared_get/shared_call)") }

1;

__END__

=head1 NAME

Data::Shared::Adapter::Map - Internal adapter for map-like mounts (Data::Shared)

=head1 DESCRIPTION

Internal to L<Data::Shared>; not a public API. Translates generic
verbs for single-key mounts (HashMap, Buffer, RadixTree, Intern,
Pool, PerfectHash) into native method calls, and builds the cached
per-verb coderefs used on the dispatch fast path.

=cut
