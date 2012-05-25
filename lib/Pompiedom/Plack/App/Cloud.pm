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

use Plack::Util::Accessor 'subscriptions_file', 'subscriptions', 'logger',
    'config';
use Plack::Request;

use DateTime;
use Data::Dumper;

use AnyEvent::HTTP;
use YAML 'DumpFile', 'LoadFile';
use Coro 'async';
use HTML::Entities 'encode_entities';
use JSON;
use Time::HiRes qw/time/;
use URI::Escape;
use URI;

my $start_time = time();

sub prepare_app {
    my $self = shift;
    $self->{subscriptions} ||= eval { LoadFile('rsscloud-psgi.yml') } || {};
    $self->{timer}         ||= AnyEvent->timer(interval => 30, cb => sub {
            $self->expire_subscriptions;
        });
    return;
}

sub save_subscriptions {
    my $self = shift;
    DumpFile($self->subscriptions_file, $self->subscriptions);
    return;
}


sub expire_subscriptions {
    my $self = shift;
    $self->logger->info("Expiring subscriptions start\n");

    while (my ($url, $clients) = each %{ $self->subscriptions }) {
        my $uri = URI->new($url);
        if (!$self->config->{watched_hosts}{$uri->host}) {
            $self->logger->info("Removing url for not watched host: $url\n");
            delete $self->subscriptions->{$url};
        }

        while (my ($client, $sub) = each %$clients) {
            if ((time()-$sub->{subscribed}) > (25*60*60)) {
                $self->logger->info("Subscription $url expired for $client\n");
                delete $self->subscriptions->{$url}{$client};
            }
            elsif ($sub->{errors} && @{$sub->{errors}} >= 5) {
                $self->logger->debug("Too many errors for $client\n");
                delete $self->subscriptions->{$url}{$client};
            }
        }
    }

    $self->save_subscriptions;
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
        $res->content('<pre>'.Dumper($self->subscriptions)."\n\n".Dumper($self->{running_stats}).'</pre>');
    }
    elsif ($req->path_info =~ m{^/stats}) {
        $res->content_type('application/json; charset=utf-8');
        $self->{running_stats}{uptime} = time() - $start_time;
        $res->content(encode_json($self->{running_stats}));
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
            for (qw/protocol port path/) {
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

            my $count = 0;

            for my $url (@urls) {
                my $uri = URI->new($url);

                # skip not watched hosts
                next if !$self->config->{watched_hosts}{$uri->host};

                my %subscription = %$subscription;

                if ($self->subscriptions->{$url}{$host}) {
                    $self->{running_stats}{resubscribe}++;
                }

                $self->{running_stats}{subscribe}++;
                $count++;
                $self->subscriptions->{$url}{$host} = \%subscription;
            }

            $self->save_subscriptions;

            if ($count > 0) {
                $res->content(<<XML);
<?xml version="1.0"?>
<result success="true" message="Subscribed" />
XML
            }
            else {
                $res->content(<<XML);
<?xml version="1.0"?>
<result success="false" message="Error: Not subscribed to any urls. The most
likely error is that this cloud doesn't these urls." />
XML
            }
        }
    }
    elsif ($req->method eq 'POST' && $req->path_info =~ m{^/ping}) {
        my $ping_url = $req->param('url');
        $self->{running_stats}{pings}++;

        $self->logger->info(sprintf('Ping (from=%s,url="%s")', $req->address, $ping_url)."\n");

        $res->content_type('application/xml; charset=utf-8');
        my @subscriptions = values %{ $self->{subscriptions}->{$ping_url} };
        
        while (my ($client, $sub) = each %{ $self->subscriptions->{$ping_url} }) {
            my $url = sprintf('http://%s:%d%s', $sub->{host}, $sub->{port}, $sub->{path});
            $self->logger->info(sprintf('Notify (url="%s")', $url)."\n");

            http_post($url, 'url='. uri_escape($ping_url), {
                    'content-type' => 'application/x-www-form-urlencoded',
                }, sub {
                    my ($data, $headers) = @_;

                    $self->{running_stats}{notifications}++;

                    if ($headers->{Status} !~ m/^2/) {
                        $self->logger->info(
                            sprintf('Notify failed with %d (url="%s")',
                                $headers->{Status}, $url)."\n");

                        $self->{running_stats}{notifications_failed}++;
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
