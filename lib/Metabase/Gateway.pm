package Metabase::Gateway;
use Moose;

use Metabase::Fact;
use Metabase::Librarian;
use Metabase::User::Profile;
use Metabase::User::Secret;

# XXX life becomes a lot easier if we say that fact classes MUST have 1-to-1
# relationship with a .pm file. -- dagolden, 2009-03-31

has fact_classes => (
  is  => 'ro',
  isa => 'ArrayRef[Str]',
  auto_deref => 1,
  required   => 1,
);

has approved_types => (
  is          =>  'ro',
  isa         =>  'ArrayRef[Str]',
  auto_deref  => 1,
  lazy        => 1,
  builder     => '_build_approved_types',
  init_arg    => undef,
);

has disable_security => (
  is          => 'ro',
  isa         => 'Bool',
  default     => 0,
);

has librarian => (
  is       => 'ro',
  isa      => 'Metabase::Librarian',
  required => 1,
);

has secret_librarian => (
  is       => 'ro',
  isa      => 'Metabase::Librarian',
  required => 1,
);

# recurse report classes -- less to specify to new()
sub _build_approved_types {
  my ($self) = @_;
  my @queue = $self->fact_classes;
  my @approved;
  while ( my $class = shift @queue ) {
    push @approved, $class;
    # XXX $class->can('fact_classes') ?? -- dagolden, 2009-03-31
    push @queue, $class->fact_classes if $class->isa('Metabase::Report');
  }
  return [ map { $_->type } @approved ];
}

# for use in handle_XXXX methods
sub _fatal {
  my ($self, $code, $reason, $details) = @_;
  $code ||= 500;
  $reason ||= "internal gateway error";
  $details ||= '';
  chomp $details;
  my $message = "$code\: $reason";
  $message .= $details if $details;
  die "$message\n";
}

sub _validate_resource {
  my ($self, $request) = @_;

  # XXX Well... yeah, eventually we'll want to reject reports for dists that
  # don't, you know, exist. -- rjbs, 2008-04-06
  1;
}

sub _validate_submitter {
  my ($self, $user_guid, $user_secret) = @_;

  return 1 if $self->disable_security;

  # check whether submitter profile is already in the Metabase
  my $profile = eval { $self->librarian->extract($user_guid); 1 }
    or die "unknown user\n";

  # check if we have a secret on file
  my $secret;
  eval { 
    my $found = $self->librarian->search( 
        'core.type' => 'Metabase-User-Secret',
        'core.resource' => $profile->resource,
    );
    unless ( defined $found->[0] ) {
      die "no secret for that user\n";
    }
    $secret = $self->secret_librarian->extract($found->[0]);
  };

  # match against submitted secret
  die "user authentication failed"
    unless defined $secret
    and    $user_secret eq $secret->content;

  # submitter is good!
  return 1;
}

sub _validate_fact_struct {
  my ($self, $struct, @approved) = @_;

  # approved fact type
  my $type = $struct->{metadata}{core}{type};
  unless ( grep { $type eq $_ } @approved ) {
    die "$type is not an approved fact type\n";
  }

  # has content
  die "no content provided" unless defined $struct->{content};

  # required metadata
  for my $key ( qw/resource type schema_version guid creator creation_time/ ) {
    my $meta = $struct->{metadata}{core}{$key};
    die "no '$key' provided in core metadata"
      unless defined $meta;
    # XXX really should check meta validity: [ //str => 'abc' ], but lets wait
    # until we decide on sugar for metadata types -- dagolden, 2009-03-31
  }

  die "submissions must not include resource or content metadata"
    if $struct->{metadata}{content} or $struct->{metadata}{resource};

  return 1;
}

sub _check_permissions {
  my ($self, $user_guid, $action, $fact) = @_;

  # The devil may care, but we don't. -- rjbs, 2009-03-30

  # E.g. do we let a user submit a fact they aren't listed as the creator for?
  # -- dagolden, 2010-02-28 

  return 1;
}

sub _thaw_fact {
  my ($self, $struct, @approved) = @_;

  $self->_validate_fact_struct($struct, @approved);
  my $type = $struct->{metadata}{core}{type};
  return Metabase::Fact->class_from_type($type)->from_struct($struct);
}

# NOTE ON ERRORS: die with _fatal( XXX => reason => details )
sub handle_submission {
  my ($self, $struct, $user_guid, $user_secret) = @_;

  # use Data::Dumper;
  # local $SIG{__WARN__} = sub { warn "@_: " . Dumper($struct); };

  # authenticate
  unless ( eval { $self->_validate_submitter( $user_guid, $user_secret ); 1 } ) {
    $self->_fatal( 401 => "unauthorized" => $@ );
  }

  # thaw
  my $fact = eval { $self->_thaw_fact($struct, $self->approved_types) };
  unless ( $fact ) {
    $self->_fatal( 400 => "invalid submission data" => $@ );
  }

  # action allowed for this submitter for this fact
  unless ( eval { $self->_check_permissions($user_guid => submit => $fact) } ) {
    $self->_fatal( 400 => "cannot accept fact from current submitter" => $@ );
  }

  # accepted by librarian
  my $guid = eval { $self->enqueue($fact) };
  unless ( $guid ) {
    $self->_fatal( 500 => "internal gateway error" => $@ );
  }

  return $guid;
}

# NOTE ON ERRORS: die with _fatal( XXX => reason => details )
sub handle_registration {
  my ($self, $profile_struct, $secret_struct) = @_;

  # thaw profile
  my $profile = eval { $self->_thaw_fact($profile_struct, 'Metabase-User-Profile') };
  unless ( $profile ) {
    $self->_fatal( 400 => "invalid submission data" => $@ );
  }

  # thaw secret 
  my $secret = eval { $self->_thaw_fact($secret_struct, 'Metabase-User-Secret') };
  unless ( $secret ) {
    $self->_fatal( 400 => "invalid submission data" => $@ );
  }

  # neither should exist
  if ( $self->librarian->exists( $profile->guid ) 
    || $self->secret_librarian->exists( $secret->guid )
  ) {
    $self->_fatal( 400 => "already registered" );
  }

  # store with respective librarians
  my ($secret_guid, $profile_guid);
  eval { 
    $secret_guid = $self->secret_librarian->store( $secret );
    $profile_guid = $self->librarian->store( $profile );
  };
  unless ( $secret_guid && $profile_guid ) {
    $self->_fatal( 500 => "internal gateway error" => $@ );
  }

  # profile accepted by librarian
  return $profile_guid;
}

sub enqueue {
  my ($self, $fact) = @_;
  return $self->librarian->store($fact);
}

1;

__END__

=pod

=head1 NAME

Metabase::Gateway - Manage Metabase fact submission

=head1 SYNOPSIS

  my $mg = Metabase::Gateway->new(
    fact_classes      => \@valid_fact_classes,
    librarian         => $librarian,
    secret_librarian  => $secret_librarian,
  );

  $mg->handle_submission( $fact_struct, $user_guid, $user_secret);

=head1 DESCRIPTION

The Metabase::Gateway class manages submissions to the Metabase.  It
provides fact and submitter validation or authorization before storing
new facts in a Metabase.

=head1 USAGE

=head2 C<new>

  my $mg = Metabase::Gateway->new(
    fact_classes      => \@valid_fact_classes,
    librarian         => $librarian,
    secret_librarian  => $secret_librarian,
  );

Gateway constructor.  Takes three required attributes C<fact_classes>,
C<librarian> and C<secret_librarian>.  See below for details.

=head1 ATTRIBUTES

=head2 C<approved_types>

Returns a list of approved fact types.  Automatically generated; cannot be
initialized.  Used for validating submitted facts.

=head2 C<disable_security>

A boolean option.  If true, submitter profiles will not be authenticated.
(This is generally useful for testing, only.) Default is false.

=head2 C<fact_classes>

Array reference containing a list of valid L<Metabase::Fact> subclasses. Only facts
from these classes may be added to the Metabase. Required.

=head2 C<librarian>

A librarian object to manage fact data. Required.

=head2 C<secret_librarian>

A librarian object to manage user profile data.  This is generally kept in a separate
data store to isolate user profile facts from public, searchable facts. Required.

=head1 METHODS

=head2 C<enqueue>

  $mg->enqueue( $fact );

Add a fact from a user (identified by a profile) to the Metabase the gateway is
managing.  Used internally by handle_submission.

=head2 C<handle_submission>

  $mg->handle_submission( $fact_struct, $user_guid, $user_secret);

Extract a fact a deserialized data structure and add it to the
Metabase. The fact is regenerated from the C<as_struct> method.

=head2 C<handle_registration>

  $mg->handle_registration( $profile_struct, $secret_struct );

Extract a new user profile and secret from deserialized data structures
and add them via the librarian and secret_librarian, respectively.

=head1 BUGS

Please report any bugs or feature using the CPAN Request Tracker.
Bugs can be submitted through the web interface at
L<http://rt.cpan.org/Dist/Display.html?Queue=Metabase>

When submitting a bug or request, please include a test-file or a patch to an
existing test-file that illustrates the bug or desired feature.

=head1 AUTHOR

=over

=item *

David A. Golden (DAGOLDEN)

=item *

Ricardo J. B. Signes (RJBS)

=back

=head1 COPYRIGHT AND LICENSE

 Portions Copyright (c) 2008-2010 by David A. Golden
 Portions Copyright (c) 2008-2009 by Ricardo J. B. Signes

Licensed under terms of Perl itself (the "License").
You may not use this file except in compliance with the License.
A copy of the License was distributed with this file or you may obtain a
copy of the License from http://dev.perl.org/licenses/

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut

