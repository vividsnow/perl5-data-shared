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
    return (_scalar_snapshot($value), 1) unless ref $value;
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

my $ENCODER;
sub _encoder { return $ENCODER ||= JSON::PP->new->allow_nonref(1) }

my $INFINITY = 9**9**9;

# The manifest is a codec, and JSON is total over neither of these. Both the
# backend constructor and the manifest see what this returns, so a path
# recorded here is the one the file was created under.
sub _scalar_snapshot {
    my ($value) = @_;
    return $value unless defined $value;
    if (utf8::is_utf8($value)) {
        # Encoded to JSON a lone surrogate, or a codepoint above the Unicode
        # range, produces text JSON::PP cannot parse again: the mount
        # succeeded and every later open croaked on a manifest only hand
        # editing could repair.
        Carp::croak('Data::Shared: mount argument is not representable in a manifest')
            if $value =~ /[\x{D800}-\x{DFFF}]|[^\x{0}-\x{10FFFF}]/;
        # A string of bytes and its character spelling are the same JSON once
        # published, and the reader cannot tell them apart, so a byte path
        # came back as characters and named a different file. Record the bytes
        # the filesystem and the leaf's SvPV already see.
        # Copied through a stringification, not assigned: a plain copy carries
        # the numeric flags a string used in numeric context has, and the
        # encoder then writes this string as a bare number -- '123' replayed as
        # 123, and one numifying to Inf as text no manifest reader accepts.
        my $bytes = "$value";
        utf8::encode($bytes);
        return $bytes;
    }
    # A scalar with no numeric flags at all cannot be written as a number, and
    # that is the common case -- a path, a key -- so settle it without an
    # encode. A perfecthash build passes its whole key list through here.
    my $flags = B::svref_2object(\$value)->FLAGS;
    return $value unless $flags & (B::SVp_IOK() | B::SVp_NOK());
    # Inf and NaN by value, not by how the encoder spells them: JSON::PP has
    # two code paths and the one selected by PERL_JSON_PP_USE_B quotes a real
    # Inf that has been stringified, which let it through. Any NV may be one:
    # int() on an Inf sets IOK too, and requiring NOK alone let every Inf that
    # had been printed or rounded first past this guard.
    if ($flags & B::SVp_NOK()) {
        my $number = 0 + $value;
        if ($number != $number || $number == $INFINITY || $number == -$INFINITY) {
            # The string 'inf' used once in numeric context is not a real Inf,
            # and before perl 5.40 the two carry identical flags, so the flags
            # cannot tell them apart -- which refused that string on every
            # perl this dist supports but the newest. The PV can: a real one
            # spells itself the way perl does, and a string keeps whatever the
            # caller wrote. Checked only when there is a PV to read, so a
            # never-stringified Inf is still refused here.
            Carp::croak("Data::Shared: '$value' is not a serializable mount argument")
                unless ($flags & B::SVp_POK()) && "$value" ne "$number";
        }
    }
    # A number with no string half of its own: its spelling is ours to
    # settle, before the encoder is consulted at all. Asked of perl, because
    # which form JSON::PP picks varies by version, by flag history, and -- as
    # four attempts at this established -- by whatever cpanm resolved that
    # day. perl's own spelling carries NV_DIG significant digits, so 2**53
    # comes back two short of what the store was built with, and 1+2**-52
    # comes back as 1.
    if (!($flags & B::SVp_POK())) {
        my $copy = $value;              # a copy: stringifying $value would
        my $short = "$copy";            # set POK and change what follows
        if (0 + $short != $value) {
            # %.0f at the integer bounds, where int() is a no-op. Otherwise the
            # width that round trips this perl's NV: 17 significant digits for a
            # double, 21 for an 80-bit long double, 36 for __float128. Tried in
            # order rather than read from Config, because the reparse below is
            # the only answer that counts.
            my @widths = $value == int($value) ? (0) : (17, 21, 36);
            for my $digits (@widths) {
                my $decimal = $digits ? sprintf('%.*g', $digits, $value)
                                      : sprintf('%.0f', $value);
                # Numified on a copy so $decimal keeps a string's flags: given
                # numeric ones, one JSON::PP writes digits and another the
                # exponent form back again.
                my $check = $decimal;
                return $decimal if $check + 0 == $value;
            }
        }
    }
    # Which of the two it writes depends on flag history the caller cannot see,
    # so ask the encoder rather than the flags: a string used once in numeric
    # context carries numeric flags and is still quoted.
    my $written = _encoder()->encode($value);
    return $value if $written =~ /\A"/;
    # Inf and NaN are written verbatim, which is not JSON. Refuse while the
    # caller is still there to be told, rather than publishing a manifest that
    # kills the store at the next topology change.
    Carp::croak("Data::Shared: '$value' is not a serializable mount argument")
        if $written =~ /\A-?(?:inf|nan)/i;
    return $value;
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
        # Existing lock modes are preserved; new locks are owner-only.
        # fcntl-based flock emulation needs O_RDWR for LOCK_SH.
        unless (sysopen($fh, $path, O_RDWR | O_APPEND | O_CREAT, 0600)) {
            my $err = $!;
            # Shared locks may use a read-only descriptor on write-protected stores.
            if (!$exclusive && -e $path && open $fh, '<', $path) {
            } else {
                $! = $err;
                Carp::croak("Data::Shared: cannot open manifest lock '$path': $!");
            }
        }
    }
    # Perl signal handlers can interrupt flock; retry EINTR.
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
        unless defined $data->{revision} && !ref $data->{revision} && $data->{revision} =~ /\A[0-9]+\z/;
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
    if (exists $data->{retained}) {
        Carp::croak("Data::Shared: invalid retained storage in '$path'")
            unless ref $data->{retained} eq 'ARRAY';
        for my $kept (@{ $data->{retained} }) {
            Carp::croak("Data::Shared: invalid retained storage in '$path'")
                unless defined $kept && !ref $kept && length $kept;
        }
    }
    # The validated manifest is trusted input; untaint paths before backend taint guards.
    # Preserve numeric argument types during untainting.
    _untaint($data);
    # Fingerprint the published bytes; JSON::PP may re-encode decoded numbers differently.
    return wantarray ? ($data, $json) : $data;
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
    # Restore published bytes after JSON decoding, including bytes above 0x7f.
    utf8::downgrade($clean, 1);
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
    # Atomic replacement must preserve administrator-set manifest permissions.
    my $mode = (stat $path)[2];
    my $ok = eval {
        chmod $mode & 07777, $tmp or die "cannot set manifest mode: $!" if defined $mode;
        # Isolate JSON output from the caller's $, and $\.
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
    return "$json\n";       # what read() will slurp back, for the fingerprint
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
