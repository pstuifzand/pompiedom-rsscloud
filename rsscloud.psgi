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

use lib 'lib';
use strict;
use warnings;

use Pompiedom::Plack::App::Cloud;
use Plack::Request;
use Plack::Builder;
use Log::Dispatch;

my $logger = Log::Dispatch->new(
    callbacks => sub { my %p = @_; return localtime() . ' [' . $p{level} . '] ' . $p{message}; },
    outputs => [
        [ 'File', min_level => 'debug', filename => 'rsscloud.log' ],
        [ 'Screen', min_level => 'debug' ],
    ]
);

builder {
    mount '/rsscloud' => Pompiedom::Plack::App::Cloud->new(
        subscriptions_file => 'rsscloud-psgi.yml',
        logger             => $logger,
    ),
};
