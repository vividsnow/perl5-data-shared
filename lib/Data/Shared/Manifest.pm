package Data::Shared::Manifest;
use strict;
use warnings;
use Carp ();
use JSON::PP ();
use Scalar::Util qw(refaddr blessed);
use Fcntl qw(:flock O_RDWR O_WRONLY O_APPEND O_CREAT);
use Errno ();
use B ();

our $VERSION = '0.01';

our @CARP_NOT = qw(Data::Shared Data::Shared::Manifest Data::Shared::Storage
                   Data::Shared::Composite);

sub snapshot {
    my ($value, $active) = @_;
    return ($value, 1) unless ref $value;
    return ($value ? JSON::PP::true() : JSON::PP::false(), 1)
        if blessed($value) && $value->isa('JSON::PP::Boolean');
    return ($value, 0) unless ref $value eq 'ARRAY' || ref $value eq 'HASH';
    $active ||= {};
    my $addr = refaddr($value);
    Carp::croak('Data::Shared: cyclic mount configuration is not supported') if $active->{$addr};
    local $active->{$addr} = 1;
    my $serializable = 1;
    if (ref $value eq 'ARRAY') {
        my @copy;
        for my $item (@$value) {
            my ($copy, $ok) = snapshot($item, $active);
            push @copy, $copy;
            $serializable &&= $ok;
        }
        return (\@copy, $serializable);
    }
    my %copy;
    for my $key (keys %$value) {
        my ($copy, $ok) = snapshot($value->{$key}, $active);
        $copy{$key} = $copy;
        $serializable &&= $ok;
    }
    return (\%copy, $serializable);
}

sub with_lock {
    my ($root, $exclusive, $code) = @_;
    return $code->() unless defined $root->{dir};
    my $path = "$root->{dir}/.manifest.lock";
    my $fh;
    if ($root->{readonly}) {
        # Legacy frozen roots may predate the lock file. Never create it here.
        return $code->() unless -e $path;
        open $fh, '<', $path or Carp::croak("Data::Shared: cannot open manifest lock '$path': $!");
    } else {
        # 0600, not the umask default: this lock serialises every topology
        # mutation, so a group-writable one lets another user hold it shut.
        # An existing lock keeps its own mode.
        # O_RDWR, not O_WRONLY: perl's fcntl emulation of flock needs read
        # intent for LOCK_SH, which open() and freeze_all request.
        unless (sysopen($fh, $path, O_RDWR | O_APPEND | O_CREAT, 0600)) {
            my $err = $!;
            # A shared lock only needs to read. Fall back so a store on a
            # read-only mount, or with a write-protected lock, can still be
            # opened; an exclusive lock genuinely needs write access.
            if (!$exclusive && -e $path && open $fh, '<', $path) {
                # fall through to flock below
            } else {
                $! = $err;
                Carp::croak("Data::Shared: cannot open manifest lock '$path': $!");
            }
        }
    }
    # Retry on EINTR: perl installs signal handlers without SA_RESTART, so any
    # process with a handler (SIGCHLD in a pre-forking server, an alarm timer)
    # had a contended lock fail spuriously.
    my $op = $exclusive ? LOCK_EX : LOCK_SH;
    until (flock $fh, $op) {
        Carp::croak("Data::Shared: cannot lock manifest: $!") unless $!{EINTR};
    }
    return $code->(); # lexical filehandle releases the lock on return or exception
}

sub read {
    my ($path) = @_;
    open my $fh, '<', $path or Carp::croak("Data::Shared: cannot read manifest '$path': $!");
    my $json = do { local $/; <$fh> };
    close $fh or Carp::croak("Data::Shared: cannot close manifest '$path': $!");
    my $data = eval { JSON::PP->new->decode($json) };
    Carp::croak("Data::Shared: invalid manifest '$path': $@") if $@;
    Carp::croak("Data::Shared: invalid manifest '$path': expected an object") unless ref $data eq 'HASH';
    Carp::croak("Data::Shared: unsupported manifest version in '$path'")
        unless defined $data->{version} && !ref $data->{version} && $data->{version} eq '1';
    Carp::croak("Data::Shared: invalid manifest mounts in '$path'") unless ref $data->{mounts} eq 'ARRAY';
    $data->{revision} = 0 unless exists $data->{revision};
    Carp::croak("Data::Shared: invalid manifest revision in '$path'")
        unless defined $data->{revision} && !ref $data->{revision} && $data->{revision} =~ /\A\d+\z/;
    # Older JSON::PP treats numeric values inspected as strings as JSON strings.
    # Restore numeric header types so validation cannot change the fingerprint.
    $data->{version} = 1;
    $data->{revision} = 0 + $data->{revision};
    my %names;
    for my $mount (@{ $data->{mounts} }) {
        Carp::croak("Data::Shared: invalid mount record in '$path'") unless ref $mount eq 'HASH';
        Carp::croak("Data::Shared: invalid mount name in '$path'")
            unless defined $mount->{name} && !ref $mount->{name} && length $mount->{name};
        Carp::croak("Data::Shared: duplicate mount '$mount->{name}' in '$path'") if $names{$mount->{name}}++;
        $mount->{args} = [] unless exists $mount->{args};
        Carp::croak("Data::Shared: invalid mount arguments in '$path'") unless ref $mount->{args} eq 'ARRAY';
        Carp::croak("Data::Shared: missing mount spec in '$path'") unless defined $mount->{spec};
    }
    # Everything decoded from the file is tainted, and the backing path is built
    # from the mount name, so under -T a leaf with a taint guard refused to
    # reopen: a store was writable once and dead afterwards. The manifest is
    # declared trusted input and has just been validated field by field, so
    # untaint it here. Numbers must stay numbers or the canonical JSON
    # fingerprint changes and _assert_revision reports a stale revision.
    _untaint($data);
    return $data;
}

sub _untaint {
    my ($node) = @_;
    if (ref $node eq 'HASH')  { $_ = _untaint_scalar($_) for values %$node; return $node }
    if (ref $node eq 'ARRAY') { $_ = _untaint_scalar($_) for @$node;        return $node }
    return $node;
}

sub _untaint_scalar {
    my ($v) = @_;
    return _untaint($v) if ref $v;
    return $v unless defined $v;
    my ($clean) = "$v" =~ /\A(.*)\z/s;      # a capture is untainted
    # JSON::PP gives numbers IOK/NOK and strings POK only, so this keeps "007"
    # a string while 1000 stays a number.
    my $flags = B::svref_2object(\$v)->FLAGS;
    return 0 + $clean if $flags & (B::SVp_IOK() | B::SVp_NOK());
    return $clean;
}

sub write {
    my ($path, $data) = @_;
    my $json = JSON::PP->new->canonical(1)->ascii(1)->encode($data);
    require File::Temp;
    require File::Basename;
    my ($fh, $tmp) = File::Temp::tempfile('.manifest-XXXXXXXX', DIR => File::Basename::dirname($path), UNLINK => 0);
    my $ok = eval {
        # A caller's $, would land between the JSON and the newline and $\ after
        # it, either of which publishes a manifest nothing can parse again.
        local ($,, $\);
        print {$fh} $json, "\n" or die "cannot write manifest: $!";
        close $fh or die "cannot close manifest: $!";
        rename $tmp, $path or die "cannot rename manifest to '$path': $!";
        1;
    };
    my $err = $@;
    if (!$ok) {
        close $fh if defined fileno($fh);
        unlink $tmp;
        Carp::croak("Data::Shared: $err");
    }
    return 1;
}

1;

__END__

=head1 NAME

Data::Shared::Manifest - Internal manifest validation and publication

=head1 DESCRIPTION

Internal to L<Data::Shared>. Copies configuration, validates version-one
manifests, and publishes revisions under a directory lock. Revisions absent
from legacy manifests are read as zero. Atomic replacement protects readers
from partial JSON; it does not promise durability across a machine crash.

=cut
