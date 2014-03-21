package Plack::Middleware::DebugLogging;

# ABSTRACT: Catalyst style console debugging for plack apps

use strict;
use warnings;

use Text::SimpleTable;
use Plack::Request;
use Plack::Response;
use Term::Size::Any;
use Plack::Util::Accessor qw(debug request response request_headers request_parameters
                             response_headers  response_status_line keywords uploads
                             body_params query_params logger logger_override term_width);

use parent qw/Plack::Middleware/;

sub prepare_app {
    my ($self) = @_;

    $self->debug(1) unless defined $self->debug;
    $self->request(1) unless defined $self->request;
    $self->response(1) unless defined $self->response;
    $self->keywords(1) unless defined $self->keywords;
    $self->request_headers(1) unless defined $self->request_headers;
    $self->request_parameters(1) unless defined $self->request_parameters;
    $self->response_headers(1) unless defined $self->response_headers;
    $self->response_status_line(1) unless defined $self->response_status_line;
    $self->uploads(1) unless defined $self->uploads;
    $self->body_params(1) unless defined $self->body_params;
    $self->query_params(1) unless defined $self->query_params;

    $self->logger_override(1) if defined $self->logger;
}

sub call {
    my($self, $env) = @_;

    my $request = Plack::Request->new($env);

    # take latest $request->logger unless it was explicitly provided at build time
    if (!$self->logger_override) {
        if ($request->logger ) {
            $self->logger($request->logger);
        }
        else {
            $self->logger(sub {
                my ($args) = @_;
                print STDERR $args->{msg};
            });
        }
    }

    $self->log_request($request) if $self->request;

    $self->response_cb($self->app->($env), sub {
        my $res = Plack::Response->new(@{shift()});
        $self->log_response($res) if $self->response;
        $res;
    });
}

sub log {
    my ($self, $msg) = @_;

    if (my $logger = $self->logger) {
        $logger->({ level => 'debug', msg => "$msg\n" });
    }
    else {
        print STDERR $msg;
    }
}

=head1 NAME

Plack::Middleware::DebugLogging - Catalyst style console debugging for plack apps

=head1 SYNOPSIS

  use Plack::Builder;

  my $app = sub { ... }

  builder {
    enable_if { $ENV{PLACK_ENV} eq 'development' } 'DebugLogging';
    $app;
  }

curl -XPOST http://0:5000/api/1/2? -d'foo=bar&foo=baz'

  "POST" request for "/api/1/2" from "127.0.0.1"
  Request Headers:
  .-----------------+---------------------------------------------------------------.
  | Header Name     | Value                                                         |
  +-----------------+---------------------------------------------------------------+
  | Accept          | */*                                                           |
  | Host            | 0:5000                                                        |
  | User-Agent      | curl/7.22.0 (i686-pc-linux-gnu) libcurl/7.22.0 OpenSSL/1.0.1- |
  |                 |  zlib/1.2.3.4 libidn/1.23 librtmp/2.3                         |
  | Content-Length  | 15                                                            |
  | Content-Type    | application/x-www-form-urlencoded                             |
  '-----------------+---------------------------------------------------------------'

  Response Code: 404; Content-Type: text/plain; Content-Length: unknown
  Response Headers:
  .-----------------+---------------------------------------------------------------.
  | Header Name     | Value                                                         |
  +-----------------+---------------------------------------------------------------+
  | Content-Type    | text/plain                                                    |
  '-----------------+---------------------------------------------------------------'

=head1 DESCRIPTION

This is a refactoring of Catalyst's debugging output for use in any Plack
application, sitting infront of a web framework or otherwise. This is ideal for
development environments. You probably would not want to run this on your
production application.

This middleware will use psgix.logger if available in the environment,
otherwise it will fall back to printing to stderr.

There are a large list of attrs which can be used to control which
output you want to see:

=over 4

=item debug

=item request

=item response

=item request_headers

=item request_parameters

=item response_headers

=item response_status_line

=item keywords

=item uploads

=item body_params

=item query_params

=back

=head1 METHODS

=head2 $self->log_request

Writes information about the request to the debug logs.  This includes:

=over 4

=item * Request method, path, and remote IP address

=item * Query keywords (see L<Catalyst::Request/query_keywords>)

=item * Request parameters

=item * File uploads

=back

=cut

sub log_request {
    my ($self, $request) = @_;

    return unless $self->debug;

    my ( $method, $path, $address ) = ( $request->method, $request->path, $request->address );
    $method ||= '';
    $path = '/' unless length $path;
    $address ||= '';
    $self->log(qq/"$method" request for "$path" from "$address"/);

    $self->log_headers('request', $request->headers)
        if $self->request_headers;

    if ( index( $request->env->{QUERY_STRING}, '=' ) < 0 ) {
        my $keywords = $self->unescape_uri($request->env->{QUERY_STRING});
        $self->log("Query keywords are: $keywords\n")
            if $keywords && $self->keywords;
        return;
    }

    $self->log_request_parameters(query => $request->query_parameters->mixed, body => $request->body_parameters->mixed)
        if $self->request_parameters;

    $self->log_request_uploads($request) if $self->uploads;
}


=head2 $self->log_response

Writes information about the response to the debug logs by calling
C<< $self->log_response_status_line >> and C<< $self->log_response_headers >>.

=cut

sub log_response {
    my ($self, $response) = @_;

    return unless $self->debug;

    $self->log_response_status_line($response) if $self->response_status_line;
    $self->log_headers('response', $response->headers) if $self->response_headers;
}

=head2 $self->log_response_status_line($response)

Writes one line of information about the response to the debug logs.  This includes:

=over 4

=item * Response status code

=item * Content-Type header (if present)

=item * Content-Length header (if present)

=back

=cut

sub log_response_status_line {
    my ($self, $response) = @_;

    $self->log(
        sprintf(
            'Response Code: %s; Content-Type: %s; Content-Length: %s',
            $response->code                              || 'unknown',
            $response->headers->header('Content-Type')   || 'unknown',
            $response->headers->header('Content-Length') || 'unknown'
        )
    );
}

=head2 $self->log_request_parameters( query => {}, body => {} )

Logs request parameters to debug logs

=cut

sub log_request_parameters {
    my $self = shift;
    my %all_params = @_;

    return unless $self->debug;

    my $column_width = $self->_term_width() - 44;
    foreach my $type (qw(query body)) {
        my $params = $all_params{$type};
        next if ! keys %$params;
        my $t = Text::SimpleTable->new( [ 35, 'Parameter' ], [ $column_width, 'Value' ] );
        for my $key ( sort keys %$params ) {
            my @param = $params->{$key};
            my $value = length($param[0]) ? $param[0] : '';
            $t->row( $key, ref $value eq 'ARRAY' ? ( join ', ', @$value ) : $value );
        }
        $self->log( ucfirst($type) . " Parameters are:\n" . $t->draw );
    }
}

=head2 $self->log_request_uploads

Logs file uploads included in the request to the debug logs.
The parameter name, filename, file type, and file size are all included in
the debug logs.

=cut

sub log_request_uploads {
    my ($self, $request) = @_;

    return unless $self->debug;

    my $uploads = $request->uploads;
    if ( keys %$uploads ) {
        my $t = Text::SimpleTable->new(
            [ 12, 'Parameter' ],
            [ 26, 'Filename' ],
            [ 18, 'Type' ],
            [ 9,  'Size' ]
        );
        for my $key ( sort keys %$uploads ) {
            my $upload = $uploads->{$key};
            for my $u ( ref $upload eq 'ARRAY' ? @{$upload} : ($upload) ) {
                $t->row( $key, $u->filename, $u->type, $u->size );
            }
        }
        $self->log( "File Uploads are:\n" . $t->draw );
    }
}

=head2 $self->log_headers($type => $headers)

Logs L<HTTP::Headers> (either request or response) to the debug logs.

=cut

sub log_headers {
    my ($self, $type, $headers) = @_;

    return unless $self->debug;

    my $column_width = $self->_term_width() - 28;
    my $t = Text::SimpleTable->new( [ 15, 'Header Name' ], [ $column_width, 'Value' ] );
    $headers->scan(
        sub {
            my ( $name, $value ) = @_;
            $t->row( $name, $value );
        }
    );
    $self->log( ucfirst($type) . " Headers:\n" . $t->draw );
}

sub env_value {
    my ( $class, $key ) = @_;

    $key = uc($key);
    my @prefixes = ( class2env($class), 'PLACK' );

    for my $prefix (@prefixes) {
        if ( defined( my $value = $ENV{"${prefix}_${key}"} ) ) {
            return $value;
        }
    }

    return;
}

sub _term_width {
    my ($self) = @_;

    return $self->term_width if $self->term_width;

    my $width = eval '
        my ($columns, $rows) = Term::Size::Any::chars;
        return $columns;
    ';

    if ($@) {
        $width = $ENV{COLUMNS}
            if exists($ENV{COLUMNS})
            && $ENV{COLUMNS} =~ m/^\d+$/;
    }

    $width = 80 unless ($width && $width >= 80);
    return $width;
}

sub unescape_uri {
    my ( $self, $str ) = @_;

    $str =~ s/(?:%([0-9A-Fa-f]{2})|\+)/defined $1 ? chr(hex($1)) : ' '/eg;

    return $str;
}

1;
