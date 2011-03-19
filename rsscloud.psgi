# RSScloud server
# Copyright (C) 2011  Peter Stuifzand
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

use strict;
use warnings;

use Time::HiRes 'gettimeofday', 'tv_interval';
use Plack::Request;
use Plack::Builder;

use Data::Dumper;
use DateTime;

use AnyEvent::HTTP;

use YAML 'DumpFile', 'LoadFile';

my %rss_urls = %{ (eval { LoadFile('rsscloud-psgi.yml') } || {}) };
my @log;

my $settings = eval { LoadFile('rsscloud-settings.yml') } || {};

push @log, { 
    event   => 'Started',
    when    => DateTime->now(),
    what    => 'Cloud Started',
    howlong => '' 
};

my $app = sub {
    my $env = shift;

    my $req = Plack::Request->new($env);
    my $res = $req->new_response(200);

    if ($req->uri->host ne $settings->{cloud}{vhost}) {
        return $req->new_response(404, [], ['<h1>Not Found</h1>'])->finalize;
    }

    if ($req->path eq '/rsscloud/') {
        $res->content_type('text/html; charset=utf-8');
        $res->content('<h1>Peter\' RSScloud</h1>
            <p>RSS Cloud in Perl, Plack, AnyEvent. <a href="/rsscloud/source">Source</a>.</p>
            <h2>License</h2>
            <p><a href="http://gnu.org/licenses/agpl-3.0.html">GNU AGPL3</a></p>
            <h2>Copyright</h2>
            <p>Copyright 2011 Peter Stuifzand</p>');
    }
    elsif ($req->path eq '/rsscloud/source') {
        $res->content_type('text/plain; charset=utf-8');
        if (open my $fh, '<', 'rsscloud.psgi') {
            my $content = do{local $/;<$fh>};
            $res->content($content);
        }
        else {
            $res->status(404);
            $res->content('not found');
        }
    }
    elsif ($req->path eq '/rsscloud/debug') {
        $res->content_type('text/html; charset=utf-8');
        $res->content('<pre>'.Dumper(\%rss_urls).'</pre>');
    }
    elsif ($req->path eq '/rsscloud/pleaseNotify') {
        my $subscription = {
            notifyProcedure => $req->param('notifyProcedure'),
            protocol => $req->param('protocol'),
            port => $req->param('port'),
            path => $req->param('path'),
            host => $req->address,
            subscribed => time(),
        };

        my $host = $subscription->{host} . ':' . $subscription->{port};
        for ($req->param) {
            if (m/url(\d+)/) {
                $rss_urls{$req->param($_)}{$host} = $subscription, 
            }
        }

        push @log, { 
            event => 'Subscribe',
            when => DateTime->now(),
            what => 'Notify '.$subscription->{host},
            howlong => '' 
        };

        DumpFile('rsscloud-psgi.yml', \%rss_urls);

        $res->content_type('application/xml; charset=utf-8');
        $res->content(<<XML);
<?xml version="1.0"?>
<result success="true" message="Subscribed" />
XML
    }
    elsif ($req->path eq '/rsscloud/ping') {

        $res->content_type('application/xml; charset=utf-8');

        my $ping_url = $req->param('url');

        push @log, { event => 'ping', when => DateTime->now(), what => 'Ping for ' . $ping_url, howlong => '' };

        my @subscriptions = values %{ $rss_urls{$ping_url} };
        
        for my $sub (@subscriptions) {

            my $url = sprintf('http://%s:%d%s',
                $sub->{host}, $sub->{port}, $sub->{path});

            push @log, { 
                event   => 'notify',
                when    => DateTime->now(),
                what    => 'Notify url '.$url,
                howlong => '' 
            };

            my $pre_start = [gettimeofday()];
            http_post($url, 'url='. $ping_url, sub {
                my ($data, $headers) = @_;
                my $howlong = tv_interval($pre_start);

                push @log, { 
                    event   => 'Notify Done',
                    when    => DateTime->now(),
                    what    => 'Notify done: status('.$headers->{Status}.') URL('.$headers->{URL}. ')',
                    howlong => $howlong,
                };
            });
        }

        $res->content(<<XML);
<?xml version="1.0"?>
<result success="true" message="Ping" />
XML
    }
    elsif ($req->path eq '/rsscloud/view_log') {
        $res->content_type('text/html; charset=utf-8');
        my $content = "<table><tr><th>Event</th><th>What Happened</th><th>When</th><th>How long (s)</th></tr>";
        @log = splice @log, 0, 100;
        for (reverse @log) {
            $content .= sprintf("<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>",
                $_->{event}, $_->{what}, $_->{when}, $_->{howlong});
        }
        $content .= "</table>";
        $res->content($content);
    }
    else {
        $res->status(404);
    }

    $res->finalize;
};

