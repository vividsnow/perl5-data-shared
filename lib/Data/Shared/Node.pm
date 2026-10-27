package Data::Shared::Node;
use strict;
use warnings;
use Carp ();
use Scalar::Util qw(blessed);

our $VERSION = '0.01';

# Croaks raised through a cursor are the caller's mistake, so Carp must not
# stop at this frame and report Node.pm as the location.
our @CARP_NOT = qw(Data::Shared);

sub new {
    my ($class, $root, $components) = @_;
    return bless { root => $root, components => [ @{ $components || [] } ] }, $class;
}

sub CLONE_SKIP { 1 }
sub root { return $_[0]{root} }
sub components { return [ @{ $_[0]{components} } ] }
sub path { return '/' . join('/', @{ $_[0]{components} }) }

sub _abs {
    my ($self, $rel) = @_;
    return [ @{ $self->{components} } ] if !defined $rel || $rel eq '' || $rel eq '/';
    if (blessed($rel)) {
        # A compiled path is a relative component list, which is what a cursor
        # appends. A Node is an absolute cursor, so appending its components
        # produced nonsense like /users/users/alice.
        return [ @{ $self->{components} }, @{ $rel->{components} } ]
            if $rel->isa('Data::Shared::Compiled');
        Carp::croak('a Data::Shared::Node is an absolute cursor, not a relative path')
            if $rel->isa('Data::Shared::Node');
    }
    # Validated as $root->node([...]) already is, or a cursor built from an
    # undef or reference component constructed silently and failed on use.
    return [ @{ $self->{components} }, @{ Data::Shared::_check_components([ @$rel ]) } ]
        if ref $rel eq 'ARRAY';
    return [ @{ $self->{components} }, @{ Data::Shared::_parse_string_path($rel) } ];
}

sub node {
    my ($self, $rel) = @_;
    return Data::Shared::Node->new($self->{root}, $self->_abs($rel));
}

sub get    { my ($s, $rel, @a) = @_; return Data::Shared::shareda_get($s->{root}, $s->_abs($rel), @a) }
sub set    { my ($s, $rel, @a) = @_; return Data::Shared::shareda_set($s->{root}, $s->_abs($rel), @a) }
sub delete {
    # An explicit undef reads as "I meant to pass something"; for the one
    # destructive verb that must not quietly mean the node's whole subtree.
    my ($s, $rel, @a) = @_;
    Carp::croak("node delete: undef relative path (pass '' for this node)")
        if @_ > 1 && !defined $rel;
    return Data::Shared::shareda_delete($s->{root}, $s->_abs($rel), @a);
}
sub exists { my ($s, $rel, @a) = @_; return Data::Shared::shareda_exists($s->{root}, $s->_abs($rel), @a) }
sub incr   { my ($s, $rel, @a) = @_; return Data::Shared::shareda_incr($s->{root}, $s->_abs($rel), @a) }
sub push   { my ($s, $rel, @a) = @_; return Data::Shared::shareda_push($s->{root}, $s->_abs($rel), @a) }
sub pop    { my ($s, $rel, @a) = @_; return Data::Shared::shareda_pop($s->{root}, $s->_abs($rel), @a) }

sub call {
    my ($self, $method, @args) = @_;
    # length too: an empty string passed this guard and the croak the caller
    # then saw named a function they had not called.
    Carp::croak("node call requires a method name") unless defined $method && length $method;
    return Data::Shared::shareda_call($self->{root}, $self->_abs(undef), $method, @args);
}

sub call_at {
    my ($self, $rel, $method, @args) = @_;
    return Data::Shared::shareda_call($self->{root}, $self->_abs($rel), $method, @args);
}

# Both took a relative path per the POD and silently ignored it.
sub children {
    my ($self, $rel) = @_;
    return $self->{root}->children($self->_abs($rel));
}

sub handle {
    my ($self, $rel) = @_;
    return $self->{root}->handle($self->_abs($rel));
}

1;

__END__

=head1 NAME

Data::Shared::Node - A cursor into a Data::Shared namespace

=head1 SYNOPSIS

    my $alice = $root->node('/users/alice');
    $alice->call('count');
    $alice->get('/event-42');
    my @kids = $root->node('/users')->children;

=head1 DESCRIPTION

Returned by C<< $root->node($path) >> and by C<shared_get> on an
intermediate composite path. Holds a root plus absolute path
components; every method appends its relative path argument (string
or arrayref, omitted for the node itself) and delegates to the
corresponding C<shareda_*> function in L<Data::Shared>.

=head2 root, components, path

Accessors. C<path> is the display form (ambiguous for components
containing C</>; use C<components> programmatically). C<components>
returns a copy.

=head2 get, set, delete, exists, incr, push, pop

Relative-path forms of the generic verbs: the relative path is always
the first argument, so addressing the node itself means passing C<''>
(C<< $node->push('', $value) >>, C<< $node->set('', $value) >>).

=head2 call($method, @args), call_at($rel, $method, @args)

C<call> invokes a native method at the node itself; C<call_at> at a
relative path below it.

=head2 node($rel), children, handle

C<node> returns a deeper cursor, C<children> lists child addresses
at a composite node, and C<handle> returns the native handle when
the node is exactly a leaf (or a composite child leaf).

=cut
