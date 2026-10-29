package Data::Shared::Adapter::Queue;
use strict;
use warnings;
use Carp ();

our $VERSION = '0.01';

our @CARP_NOT = qw(Data::Shared);

# Nothing in this family keys its push or pop, and only ringbuffer's get reads
# a component, so a longer path is the caller's mistake and not an argument.
# Forwarded as leading arguments, a push to '/jobs/5' inserted with priority 5
# on a heap, and on the others it surfaced as the backend's own arity error,
# blaming its API instead of the path. The map, set and sketch families refuse
# the same shape.
# Only the message is a sub call: the comparison is inlined at each call-time
# site, because a call on every push cost more than the rest of the check.
# Through a node cursor the relative path comes first, so addressing the node
# itself means passing '' -- the same convention Node::delete documents.
sub _too_long {
    my ($entry, $what, $max) = @_;
    Carp::croak("path too long: $entry->{key} takes "
        . ($max ? 'one path component' : "no path component for $what")
        . "; pass the value as an argument"
        . ($max ? '' : " (through a node cursor: \$node->$what('', \$value))"));
}

sub make_verb {
    my ($class, $verb, $handle, $entry) = @_;
    my $verbs = $entry->{verbs} || {};
    return undef unless exists $verbs->{$verb} && defined $verbs->{$verb};
    my $spec = $verbs->{$verb};
    if (ref $spec eq 'CODE') {
        return sub { my ($rest, @a) = @_; _too_long($entry, $verb, 1) if @$rest > 1;
                     return $spec->($handle, @$rest, @a) };
    }
    my $method = $handle->can($spec);
    if (!$method) {
        my $msg = "$entry->{key}: handle does not support '$spec'";
        return sub { Carp::croak($msg) };
    }
    return sub { my ($rest, @a) = @_; _too_long($entry, $verb, 1) if @$rest > 1;
                 return $handle->$method(@$rest, @a) };
}


sub make_bound {
    my ($class, $verb, $handle, $entry, $rest) = @_;
    my $verbs = $entry->{verbs} || {};
    return undef unless exists $verbs->{$verb} && defined $verbs->{$verb};
    my $spec = $verbs->{$verb};
    _too_long($entry, $verb, 1) if $rest && @$rest > 1;    # bind time, once
    my @idx = @$rest;
    if (ref $spec eq 'CODE') {
        return sub { my @a = @_; return $spec->($handle, @idx, @a) };
    }
    my $method = $handle->can($spec);
    if (!$method) {
        my $msg = "$entry->{key}: handle does not support '$spec'";
        return sub { Carp::croak($msg) };
    }
    return sub { my @a = @_; return $handle->$method(@idx, @a) };
}

sub make_bound_push {
    my ($class, $handle, $entry, $rest) = @_;
    return _make_pushpop($entry, $handle, 'push', $rest);
}

sub make_bound_pop {
    my ($class, $handle, $entry, $rest) = @_;
    return _make_pushpop($entry, $handle, 'pop', $rest);
}

sub perform {
    my ($class, $verb, $handle, $entry, $rest, @args) = @_;
    my $code = $class->make_verb($verb, $handle, $entry);
    Carp::croak("operation '$verb' is not supported for queue mount '$entry->{key}'; use shared_push/shared_pop or shared_call")
        unless $code;
    return $code->($rest, @args);
}

sub _make_pushpop {
    my ($entry, $handle, $field, $rest) = @_;
    my $name = $entry->{$field};
    return undef unless $name;
    my $method = $handle->can($name);
    if (!$method) {
        my $msg = "$entry->{key}: handle does not support '$name'";
        return sub { Carp::croak($msg) };
    }
    if (defined $rest) {
        _too_long($entry, $field, 0) if @$rest;            # bind time, once
        # Copy, as every other bound closure does: forwarding @_ uncopied would
        # pass the caller's own SVs to the backend.
        return sub { my @a = @_; return $handle->$method(@a) };
    }
    return sub { my ($r, @a) = @_; _too_long($entry, $field, 0) if @$r;
                 return $handle->$method(@a) };
}

sub make_push { my ($class, $handle, $entry) = @_; return _make_pushpop($entry, $handle, 'push') }
sub make_pop  { my ($class, $handle, $entry) = @_; return _make_pushpop($entry, $handle, 'pop') }

sub perform_push {
    my ($class, $handle, $entry, $rest, @args) = @_;
    my $code = $class->make_push($handle, $entry);
    Carp::croak("push is not supported for $entry->{key} (use shared_call)") unless $code;
    return $code->($rest, @args);
}

sub perform_pop {
    my ($class, $handle, $entry, $rest, @args) = @_;
    my $code = $class->make_pop($handle, $entry);
    Carp::croak("pop is not supported for $entry->{key} (use shared_call)") unless $code;
    return $code->($rest, @args);
}

1;

__END__

=head1 NAME

Data::Shared::Adapter::Queue - Internal adapter for queue-like mounts (Data::Shared)

=head1 DESCRIPTION

Internal to L<Data::Shared>; not a public API. Maps C<push>/C<pop>
sugar to each leaf's native pair (Queue C<push/pop>, Deque
C<push_back/pop_front>, Stack C<push/pop>, Heap C<push/pop>, Log
C<append>, PubSub C<publish>, RingBuffer C<write>) and serves the few
generic verbs queue mounts honestly support.

=cut
