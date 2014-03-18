package Plack::Middleware::DebugLogging;

use strict;
use warnings;

use Text::SimpleTable;
use Plack::Request;
use Plack::Response;
use Term::Size::Any;

use parent qw/Plack::Middleware/;

sub call {
    my($self, $env) = @_;

    $self->{logger} = $env->{'psgix.logger'} ||= sub {
        my ($level, $msg) = @_;
        print STDERR $msg;
    };

    my $request = Plack::Request->new($env);
    $self->log_request($request);

    $self->response_cb($self->app->($env), sub {
        my $res = Plack::Response->new(@{shift()});
        $self->log_response($res);
    });
}

sub log {
    my ($self, $msg) = @_;

    $self->{logger}->('debug', "$msg\n");
}

sub debug {
    # TODO this should be config param
    1;
}

=head2 $c->log_request

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

    $self->log_headers('request', $request->headers);

    #if ( my $keywords = $request->query_keywords ) {
    #    $self->log("Query keywords are: $keywords");
    #}

    $self->log_request_parameters(query => $request->query_parameters->mixed, body => $request->body_parameters->mixed);

    $self->log_request_uploads($request);
}


=head2 $self->log_response

Writes information about the response to the debug logs by calling
C<< $self->log_response_status_line >> and C<< $self->log_response_headers >>.

=cut

sub log_response {
    my ($self, $response) = @_;

    return unless $self->debug;

    $self->log_response_status_line($response);
    $self->log_headers('response', $response->headers);
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

    my $column_width = $self->term_width() - 44;
    foreach my $type (qw(query body)) {
        my $params = $all_params{$type};
        next if ! keys %$params;
        my $t = Text::SimpleTable->new( [ 35, 'Parameter' ], [ $column_width, 'Value' ] );
        use DDP; p $params;
        for my $key ( sort keys %$params ) {
            my @param = $params->{$key};
            my $value = length($param[0]) ? $param[0] : '';
            $t->row( $key, ref $value eq 'ARRAY' ? ( join ', ', @$value ) : $value );
        }
        $self->log( ucfirst($type) . " Parameters are:\n" . $t->draw );
    }
}

=head2 $c->log_request_uploads

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

    my $column_width = $self->term_width() - 28;
    my $t = Text::SimpleTable->new( [ 15, 'Header Name' ], [ $column_width, 'Value' ] );
    $headers->scan(
        sub {
            my ( $name, $value ) = @_;
            $t->row( $name, $value );
        }
    );
    $self->log( ucfirst($type) . " Headers:\n" . $t->draw );
}

=head2 env_value($class, $key)

Checks for and returns an environment value. For instance, if $key is
'home', then this method will check for and return the first value it finds,
looking at $ENV{MYAPP_HOME} and $ENV{CATALYST_HOME}.

=cut

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

=head2 term_width

Try to guess terminal width to use with formatting of debug output

All you need to get this work, is:

1) Install Term::Size::Any, or

2) Export $COLUMNS from your shell.

(Warning to bash users: 'echo $COLUMNS' may be showing you the bash
variable, not $ENV{COLUMNS}. 'export COLUMNS=$COLUMNS' and you should see
that 'env' now lists COLUMNS.)

As last resort, default value of 80 chars will be used.

=cut

sub term_width {
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

1;
