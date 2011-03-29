# Copyright (C) 2011 Peter Stuifzand
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
# 
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package Pompiedom::Plack::App::Cloud;

use strict;
use warnings;
use parent qw/Plack::Component/;

use Plack::Util::Accessor 'subscriptions_file', 'subscriptions';
use Plack::Request;

use DateTime;
use Data::Dumper;

use AnyEvent::HTTP;
use YAML 'DumpFile', 'LoadFile';
use HTML::Entities 'encode_entities';

sub prepare_app {
    my $self = shift;
    $self->{subscriptions} = eval { LoadFile('rsscloud-psgi.yml') } || {};
    return;
}

sub save_subscriptions {
    my $self = shift;
    DumpFile($self->subscriptions_file, $self->subscriptions);
    return;
}

sub call {
    my $self = shift;
    my $env = shift;

    my $req = Plack::Request->new($env);
    my $res = $req->new_response(200);

    if ($req->path_info =~ m{^/?$}) {
        $res->content_type('text/html; charset=utf-8');
        $res->content('<h1>Peter\' RSScloud</h1>
            <p>RSS Cloud in Perl, Plack, AnyEvent.</p>
            <h2>License</h2>
            <p><a href="http://gnu.org/licenses/agpl-3.0.html">GNU AGPL3</a></p>
            <h2>Source code</h2>
            <p>Get the code at <a href="http://github.com/pstuifzand/pompiedom-rsscloud">http://github.com/pstuifzand/pompiedom-rsscloud</a>.</p>
            <h2>Copyright</h2>
            <p>Copyright 2011 <a href="http://peterstuifzand.com/">Peter Stuifzand</a></p>');
    }
    elsif ($req->path_info =~ m{^/debug$}) {
        $res->content_type('text/html; charset=utf-8');
        $res->content('<pre>'.Dumper($self->subscriptions).'</pre>');
    }
    elsif ($req->method eq 'POST' && $req->path_info =~ m{^/pleaseNotify$}) {
        $res->content_type('application/xml; charset=utf-8');

        my $subscription = {
            notifyProcedure => scalar $req->param('notifyProcedure'),
            protocol        => scalar $req->param('protocol'),
            port            => scalar $req->param('port'),
            path            => scalar $req->param('path'),
            host            => $req->address,
            subscribed      => time(),
        };

        my @urls;
        for ($req->param) {
            if (m/url(\d+)/) {
                push @urls, $req->param($_);
            }
        }

        eval {
            for (qw/notifyProcedure protocol port path/) {
                if (!$subscription->{$_}) {
                    die "No '$_' parameter provided in POST request";
                }
            }
            if ($subscription->{port} !~ m/^\d+$/) {
                die "Parameter 'port' should be a number";
            }
            if ($subscription->{protocol} ne 'http-post') {
                die "Protocol '".$subscription->{protocol}."' is not supported";
            }
        };
        if ($@) {
            my $err = $@;
            $err =~ s{\s+at.*\n$}{};
            $err = encode_entities($err);
            $res->content(<<"XML");
<?xml version="1.0"?>
<result success="false" message="Not subscribed: $err" />
XML
        }
        else {
            my $host = $subscription->{host} . ':' . $subscription->{port};

            for (@urls) {
                $self->subscriptions->{$_}{$host} = $subscription;
            }

            $self->save_subscriptions;

            $res->content(<<XML);
<?xml version="1.0"?>
<result success="true" message="Subscribed" />
XML
        }
    }
    elsif ($req->method eq 'POST' && $req->path_info =~ m{^/ping}) {
        $res->content_type('application/xml; charset=utf-8');

        my $ping_url = $req->param('url');

        my @subscriptions = values %{ $self->{subscriptions}->{$ping_url} };
        
        while (my ($client, $sub) = each %{ $self->subscriptions->{$ping_url} }) {
            my $url = sprintf('http://%s:%d%s', $sub->{host}, $sub->{port}, $sub->{path});

            http_post($url, 'url='. $ping_url, sub {
                my ($data, $headers) = @_;

                if ($headers->{Status} !~ m/^2/) {
                    print "Ping failed\n";
                    push @{$self->subscriptions->{$ping_url}{$client}{errors}}, {
                        error  => 1,
                        status => $headers->{Status},
                        reason => $headers->{Reason},
                    };
                    $self->save_subscriptions;
                }
            });
        }

        $res->content(<<XML);
<?xml version="1.0"?>
<result success="true" message="Ping" />
XML
    }
    else {
        $res->status(404);
        $res->content_type('text/html');
        $res->content('<h1>Not found</h1>');
    }

    $res->finalize;
}


1;
