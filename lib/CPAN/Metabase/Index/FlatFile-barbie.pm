# Copyright (c) 2008 by Ricardo Signes. All rights reserved.
# Licensed under terms of Perl itself (the "License").
# You may not use this file except in compliance with the License.
# A copy of the License was distributed with this file or you may obtain a 
# copy of the License from http://dev.perl.org/licenses/

package CPAN::Metabase::Index::FlatFile;
use Moose;
use Moose::Util::TypeConstraints;

use Carp ();
use Fcntl ':flock';
use IO::File ();
use JSON::XS;

our $VERSION = '0.01';
$VERSION = eval $VERSION; # convert '1.23_45' to 1.2345

with 'CPAN::Metabase::Index';

subtype 'File' 
    => as 'Object' 
        => where { $_->isa( "Path::Class::File" ) };

coerce 'File' 
    => from 'Str' 
        => via { Path::Class::file($_) };

has 'index_file' => (
    is => 'ro', 
    isa => 'File',
    coerce => 1,
    required => 1, 
);

sub add {
    my ($self, $fact) = @_;
    Carp::confess( "can't index a Fact without a GUID" ) unless $fact->guid;

    my $fh = IO::File->new( $self->index_file, "r" )
        or Carp::confess( "Couldn't open '$self->{index_file}': $!" );
    flock $fh, LOCK_EX;
    my $last;
    while( my $line = <$fh> ) { $last = $line; }

    my $seq = 0;
    if($last) {
        my $parsed = JSON::XS->new->decode($last);
        $seq = $parsed->{sequence};
    }
    
    my $line = JSON::XS->new->encode({
      type      => $fact->type,
      timestamp => time,
      sequence  => ++$seq,
      guid      => $fact->guid->as_string,
      map {; $_ => $fact->{$_} } grep { $_ ne 'content' and $_ ne 'guid' } sort keys %$fact,
    });

    $fh->close;
        
    $fh = IO::File->new( $self->index_file, "a+" )
        or Carp::confess( "Couldn't append to '$self->{index_file}': $!" );
    $fh->binmode(':raw');
    {   
        seek $fh, 2, 0; # end
        print {$fh} $line, "\n";
    }
    $fh->close;
}

sub search {
    my ($self, %spec) = @_;
    
    my $fh = IO::File->new( $self->index_file, "r" )
        or Carp::confess( "Couldn't read from '$self->{index_file}': $!" );
    $fh->binmode(':raw');

    my @matches;
    flock $fh, LOCK_SH;
    {
        while ( my $line = <$fh> ) {
            my $parsed = JSON::XS->new->decode($line);
            push @matches, $parsed->{guid} if _match( $parsed, \%spec );
        }
    }    
    $fh->close;

    return \@matches;
}

sub exists {
    my ($self, $guid) = @_;
    return scalar @{ $self->search( guid => $guid ) };
}

sub _match {
    my ($parsed, $spec) = @_;
    for my $k ( keys %$spec ) {
        return unless  defined($parsed->{$k}) 
                    && defined($spec->{$k}) 
                    && $parsed->{$k} eq $spec->{$k};
    }
    return 1;
}

sub next_guid {
    my ($self, $guid) = @_;
    my $fh = IO::File->new( $self->index_file, "r" )
        or Carp::confess( "Couldn't open '$self->{index_file}': $!" );
    my $next = 0;
    while( my $line = <$fh> ) { 
        my $parsed = JSON::XS->new->decode($line);
        $next = 1   if( $parsed->{guid} == $guid );
        return $parsed->{guid}  if( $next && $parsed->{type} == $spec{type} );
    }
    return;
}

sub prev_guid {
    my ($self, %spec) = @_;
    my $fh = IO::File->new( $self->index_file, "r" )
        or Carp::confess( "Couldn't open '$self->{index_file}': $!" );
    my $prev;
    while( my $line = <$fh> ) { 
        my $parsed = JSON::XS->new->decode($line);
        return $prev                if( $parsed->{guid} == $guid );
        $guid = $parsed->{guid}     if( $parsed->{type} == $spec{type} );
    }
    return;
}

sub max_guid {
    my ($self, %spec) = @_;

    my $fh = IO::File->new( $self->index_file, "r" )
        or Carp::confess( "Couldn't open '$self->{index_file}': $!" );
    my $guid;
    while( my $line = <$fh> ) { 
        my $parsed = JSON::XS->new->decode($line);
        $guid = $parsed->{guid} if( $parsed->{type} == $spec{type} );
    }
    return $guid;
}

sub seq_guid {
    my ($self, @guids) = @_;
    my %guids = map {$_ => undef} @guids;

    my $fh = IO::File->new( $self->index_file, "r" )
        or Carp::confess( "Couldn't open '$self->{index_file}': $!" );
    while( my $line = <$fh> ) { 
        my $parsed = JSON::XS->new->decode($line);
        $guids{$parsed->{quid}} = $parsed->{sequence}    if( exists $guids{$parsed->{quid}} );
    }
    return sort {$guids{$a} <=> $guids{$b}} keys %guids;
}


1;

=head1 NAME

CPAN::Metabase::Index::FlatFile - CPAN::Metabase flat-file index

=head1 SYNOPSIS


=head1 DESCRIPTION

Description...

=head1 USAGE

Usage...

=head1 BUGS

Please report any bugs or feature using the CPAN Request Tracker.  
Bugs can be submitted through the web interface at 
L<http://rt.cpan.org/Dist/Display.html?Queue=CPAN-Metabase>

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

 Portions copyright (c) 2008 by David A. Golden
 Portions copyright (c) 2008 by Ricardo J. B. Signes

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
