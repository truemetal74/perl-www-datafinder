package WWW::Datafinder;

use 5.010;
use strict;
use warnings;

=head1 NAME

WWW::Datafinder - Perl API for Datafinder L<< http://datafinder.com >> API for marketing data append

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

use Carp qw(cluck);
use Data::Dumper;
use REST::Client;
use JSON::XS;
use URI;
use Scalar::Util qw(blessed reftype);
use Readonly;
use Exporter 'import';

use Mouse;

#** @attr public api_key $api_key API access key
#*
has api_key => ( isa => 'Str', is => 'rw', required => 1 );

#** @attr public Int $retries How many times retry upon timeout
#*
has retries => ( isa => 'Int', is => 'rw', default => 5 );

#** @attr protected String $base_url Base REST URL
#*
has base_url => (
    isa     => 'Str',
    is      => 'rw',
    default => 'http://api.datafinder.com/qdf.php'
);

#** @attr protected CodeRef $ua Reference to the REST UA
#*
has ua => (
    isa      => 'Object',
    is       => 'rw',
    lazy     => 1,
    init_arg => undef,
    default  => sub {
        return REST::Client->new();
    }
);

#** @attr public String $error_message Error message regarding the last failed operation
#*
has error_message =>
  ( isa => 'Str', is => 'rw', init_arg => undef, default => '' );

sub _url {
    my ( $self, $query_params ) = @_;

    $query_params //= {};
    my $uri = URI->new( $self->base_url, 'http' );
    $uri->query_form($query_params);
    #print "URL=".$uri->as_string;
    return $uri->as_string;
}

sub _process_response {
    my ( $self, $response ) = @_;

    if ($@) {
        $self->error_message("Error $@");
        return undef;
    } elsif ( !blessed($response) ) {
        $self->error_message(
            "Unknown response $response from the REST client instead of object"
        );
        return undef;
    }
    print "Got response:"
      . Dumper( $response->responseCode() ) . "/"
      . Dumper( $response->responseContent() ) . "\n"
      if $ENV{DEBUG};
    my $code = $response->responseCode();
    my $parsed_content = eval { decode_json( $response->responseContent() ) };
    if ($@) {
        cluck(  "Cannot parse response content "
              . $response->responseContent()
              . ", error msg: $@. Is this JSON?" );
        $parsed_content = {};
    }
    print "parsed " . Dumper($parsed_content) if $ENV{DEBUG};
    if ( $code ne '200' && $code ne '201' ) {
        my $err = "Received error code $code from the server instead of "
          . 'expected 200/201';
        if ( reftype($parsed_content) eq 'HASH'
            && $parsed_content->{message} )
        {
            $err .=
                "\nError message from server: "
              . $parsed_content->{message}
              . (
                $parsed_content->{error_code}
                ? ' (' . $parsed_content->{error_code} . ')'
                : q{}
              );

            $self->error_message($err);
        }
        return undef;
    }

    $self->error_message(q{});
    return $parsed_content;
}

sub _transaction {
    my ( $self, $query_params, $data ) = @_;

    $data //= {};
    $query_params->{k2} = $self->api_key unless $query_params->{k2};
    my $url = $self->_url($query_params);
    my $headers = { 'Content-Type' => 'application/json' };
    my $response;
    #    print "JSON data ".encode_json($data);
    for my $try ( 1 .. $self->retries ) {
        $response =
          eval { $self->ua->POST( $url, encode_json($data), $headers ); };
        if ($@) {
            cluck($@);
            sleep( int( 1 + rand() * 3 ) * $try );
        }
    }
    return $self->_process_response($response);
}

=head1 SYNOPSIS

    use WWW::Datafinder;
    use Text::CSV_XS;
    use Data::Dumper;

    my $csv = Text::CSV_XS->new;
    my $df  = WWW::Datafinder->new( {
          api_key   => '456' # place real API key here
    }) or die 'Cannot create Datafinder object';

    # process a CSV file with 6 columns:
    # First Name, Last Name, Address, City, State, ZIP
    while(<>) {
      chomp;
      my $status = $csv->parse($_);
      unless ($status) {
          warn qq{Cannot parse '$_':}.$csv->error_diag();
          next;
      }
      my ($name, $surname, $addr, $city, $state, $zip) = $csv->fields();
      my $data = {
            d_first    => $name,
            d_last     => $surname,
            d_fulladdr => $addr,
            d_city     => $city,
            d_state    => $state,
            d_zip      => $zip
      };
      my $res = $df->append_email($data);
      if ($res) {
        if ( $res->{'num-results'} ) {
            # there is a match!
            print "Got a match for $name $surname: " . Dumper( $res->{results} );
        }
      }
    }
 
=head1 CONSTRUCTOR

=head2 new( hashref )

Creates a new object, acceptable parameters are:

=over 16

=item C<api_key> - (required) the key to be used for read operations

=item C<retries> - how many times retry the request upon error (e.g. timeout). Default is 5.

=back

=head1 METHODS

=head2 append_email( $data )

Attempts to append customer's email based on his/her name and address (or phone
number). Please see L<< https://datafinder.com/api/docs-demo >> for more
info regarding the parameter names and format of their values in C<$data>.
Returns a reference to a hash, which contains the response
received from the server.
Returns C<undef> on failure, application then may call
C<error_message()> method to get the detailed info about the error.

    my $res = $df->append_email(
        {
            d_fulladdr => $cust->{Address},
            d_city     => $cust->{City},
            d_state    => $cust->{State},
            d_zip      => $cust->{ZIP},
            d_first    => $cust->{Name},
            d_last     => $cust->{Surname}
        }
    );
    if ( $res ) {
        if ( $res->{'num-results'} ) {
            # there is a match!
            print "Got a match: " . Dumper( $res->{results} );
        }
    } else {
        warn 'Something went wrong ' . $df->error_message();
    }

=cut

sub append_email {
    my ( $self, $data ) = @_;
    $data->{service} = 'email';

    return $self->_transaction( $data, {} );
}

=head2 error_message()

Returns the detailed explanation of the last error. Empty string if
everything went fine.

    my $res = $df->append_email($cust_data);
    unless ($res) {
        warn 'Something went wrong '.$df->error_message();
    }

If you want to troubleshoot the data being sent between the client and the
server - set environment variable DEBUG to a positive value.

=cut

=head1 AUTHOR

Andrew Zhilenko, C<< <perl at putinhuylo.org> >>
(c) Putin Huylo LLC, 2017

=head1 BUGS

Please report any bugs or feature requests to C<bug-www-datafinder at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=WWW-Datafinder>. 
I will be notified, and then you'll automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc WWW::Datafinder


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=WWW-Datafinder>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/WWW-Datafinder>

=back

=head1 LICENSE AND COPYRIGHT

Copyright 2017 Putin Huylo LLC

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, use, offer to sell, sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


=cut

__PACKAGE__->meta->make_immutable;

1;    # End of WWW::Datafinder
