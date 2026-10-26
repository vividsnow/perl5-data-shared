package Data::Shared::Adapter::Set;
use strict;
use warnings;
use Carp ();

our $VERSION = '0.01';

our @CARP_NOT = qw(Data::Shared);

sub _key {
    my ($entry, $rest, $verb) = @_;
    Carp::croak("path too short: mount has no member") unless @$rest;
    return join('/', @$rest) if $entry->{key_join};
    Carp::croak("path too long: $entry->{key} takes one member component")
        if @$rest > 1;
    # See Adapter::Map::_key: an integer-addressed member numified to element
    # 0. exists is exempt and refuses the shape in its own verb.
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
sub perform_push { Carp::croak("push is not supported for set mounts (use shared_set/shared_call)") }
sub perform_pop  { Carp::croak("pop is not supported for set mounts (use shared_call)") }

1;

__END__

=head1 NAME

Data::Shared::Adapter::Set - Internal adapter for set-like mounts (Data::Shared)

=head1 DESCRIPTION

Internal to L<Data::Shared>; not a public API. Translates generic
verbs for single-member mounts (Bloom filters, BitSet, RoaringBitmap,
SortedSet, DisjointSet) into native method calls, and builds the
cached per-verb coderefs used on the dispatch fast path.

=cut
