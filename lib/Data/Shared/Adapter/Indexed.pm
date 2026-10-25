package Data::Shared::Adapter::Indexed;
use strict;
use warnings;
use Carp ();
use parent 'Data::Shared::Adapter';
use Data::Shared::Registry ();      # the argument guards live there

our $VERSION = '0.01';

our @CARP_NOT = qw(Data::Shared);

# Every component of an indexed path is an index. See Adapter::Map::_key for
# why the check lives with the key handling: a bound closure resolves its
# indices once, so the compiled tier pays nothing per call.
# Fixed for the lifetime of a handle, so the closures below resolve it once
# instead of asking an NDArray mount its rank on every call.
sub _dims {
    my ($entry, $handle) = @_;
    my $dims = $entry->{dims};
    return $dims if defined $dims;
    return $handle && $handle->can('ndim') ? $handle->ndim : undef;
}

sub _check_indices {
    my ($entry, $rest, $verb, $dims) = @_;
    Carp::croak("Data::Shared: path too short: mount has no index") unless @$rest;
    # The verb unpacks the indices it wants and the rest fall through to its
    # argument list, so without a bound '/fenwick/1/99' set index 1 to 99.
    Carp::croak("Data::Shared: path too long: $entry->{key} takes "
        . ($dims == 1 ? 'one index component' : "$dims index components"))
        if defined $dims && @$rest > $dims;
    return unless $entry->{key_int} && $verb ne 'exists';
    Data::Shared::Registry::_assert_index($entry->{key}, $_) for @$rest;
    return;
}

sub make_verb {
    my ($class, $verb, $handle, $entry) = @_;
    my $spec = Data::Shared::Adapter::_spec($entry, $verb);
    return undef unless defined $spec;
    my $dims = _dims($entry, $handle);      # bind time: the closures capture it
    if (ref $spec eq 'CODE') {
        return sub {
            my ($rest, @a) = @_;
            _check_indices($entry, $rest, $verb, $dims);
            return $spec->($handle, @$rest, @a);
        };
    }
    my $method = $handle->can($spec);
    if (!$method) {
        my $msg = Data::Shared::Adapter::_unsupported($entry, $handle, $spec);
        return sub { Carp::croak($msg) };
    }
    if ($verb eq 'set' || $verb eq 'incr') {
        return sub {
            my ($rest, @a) = @_;
            Data::Shared::Registry::_assert_delta($entry->{key}, @a) if $verb eq 'incr';
            _check_indices($entry, $rest, $verb, $dims);
            return $handle->$method(@$rest, @a);
        };
    }
    return sub {
        my ($rest) = @_;
        _check_indices($entry, $rest, $verb, $dims);
        return $handle->$method(@$rest);
    };
}


sub make_bound {
    my ($class, $verb, $handle, $entry, $rest) = @_;
    my $spec = Data::Shared::Adapter::_spec($entry, $verb);
    return undef unless defined $spec;
    _check_indices($entry, $rest, $verb, _dims($entry, $handle));
    my @idx = @$rest;
    if (ref $spec eq 'CODE') {
        return sub { my @a = @_; return $spec->($handle, @idx, @a) };
    }
    my $method = $handle->can($spec);
    if (!$method) {
        my $msg = Data::Shared::Adapter::_unsupported($entry, $handle, $spec);
        return sub { Carp::croak($msg) };
    }
    if ($verb eq 'set' || $verb eq 'incr') {
        return sub {
            my @a = @_;
            Data::Shared::Registry::_assert_delta($entry->{key}, @a) if $verb eq 'incr';
            return $handle->$method(@idx, @a);
        };
    }
    return sub { return $handle->$method(@idx) };
}

sub perform_push { Carp::croak("Data::Shared: push is not supported for indexed mounts (use shared_call)") }
sub perform_pop  { Carp::croak("Data::Shared: pop is not supported for indexed mounts (use shared_call)") }

1;

__END__

=head1 NAME

Data::Shared::Adapter::Indexed - Internal adapter for indexed mounts (Data::Shared)

=head1 DESCRIPTION

Internal to L<Data::Shared>; not a public API. Translates generic
verbs for multi-index mounts (NDArray, Fenwick, Fenwick2D,
SegmentTree, Graph), where all remaining path components are
indices or coordinates, into native method calls.

=cut
