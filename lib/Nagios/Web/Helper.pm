package Nagios::Web::Helper;

use strict;
use warnings;
use Config::General;
use Carp;
use Nagios::MKLivestatus::MULTI;


##############################################
# calculate a duration in the
# format: 0d 0h 29m 43s
sub filter_duration {
    my $duration = shift;

    if($duration < 0) { $duration = time() + $duration; }

    my $days    = 0;
    my $hours   = 0;
    my $minutes = 0;
    my $seconds = 0;
    if($duration > 86400) {
        $days     = int($duration/86400);
        $duration = $duration%86400;
    }
    if($duration > 3600) {
        $hours    = int($duration/3600);
        $duration = $duration%3600;
    }
    if($duration > 60) {
        $minutes  = int($duration/60);
        $duration = $duration%60;
    }
    $seconds = $duration;

    return($days."d ".$hours."h ".$minutes."m ".$seconds."s");
}

######################################
# parse the cgi.cg
sub get_cgi_cfg {
    my ( $self, $c ) = @_;

    $c->stats->profile(begin => "Helper::get_cgi_cfg()");

    # read only once per request
    our(%config, $cgi_config_already_read);

    return(\%config) if $cgi_config_already_read;

    $cgi_config_already_read = 1;

    my $file = Nagios::Web->config->{'cgi_cfg'};

    if(!defined $file or $file eq '') {
        Nagios::Web->config->{'cgi_cfg'} = 'undef';
        $c->log->error("cgi.cfg not set");
        $c->error("cgi.cfg not set");
        $c->detach('/error/index/4');
    }
    if(! -r $file) {
        $c->log->error("cgi.cfg not readable: ".$!);
        $c->error("cgi.cfg not readable: ".$!);
        $c->detach('/error/index/4');
    }

    my $conf = new Config::General($file);
    %config  = $conf->getall;

    $c->stats->profile(end => "Helper::get_cgi_cfg()");

    return(\%config);
}

######################################
# return the livestatus object
sub get_livesocket {
    my ( $self, $c ) = @_;

    $c->stats->profile(begin => "Helper::get_livesocket()");

    our $livesocket;

    if(defined $livesocket) {
        $c->log->debug("got livestatus from cache");
        return($livesocket);
    }
    $c->log->debug("creating new livestatus");

    my $livesocket_path = Nagios::Web->config->{'livesocket'};
    if(!defined $livesocket_path) {
        $livesocket_path = $self->_get_livesocket_path_from_nagios_cfg(Nagios::Web->config->{'cgi_cfg'});
    }

    $c->log->debug("connecting via: ".join(', ', @{$livesocket_path})) if ref $livesocket_path eq 'ARRAY';
    $c->log->debug("connecting via: ".$livesocket_path)                if ref $livesocket_path ne 'ARRAY';

    $livesocket = Nagios::MKLivestatus::MULTI->new(
                            peer             => $livesocket_path,
                            verbose          => Nagios::Web->config->{'livesocket_verbose'},
                            keepalive        => 1,
                            logger           => $c->log,
    );

    $c->stats->profile(end => "Helper::get_livesocket()");

    return($livesocket);
}

########################################
sub sort {
    my $self  = shift;
    my $c     = shift;
    my $data  = shift;
    my $key   = shift;
    my $order = shift;
    my @sorted;

    $c->stats->profile(begin => "Helper::sort()");

    $order = "ASC" if !defined $order;

    return if !defined $data;
    return if scalar @{$data} == 0;

    my @keys;
    if(ref($key) eq 'ARRAY') {
        @keys = @{$key};
    } else {
        @keys = ($key);
    }

    my @compares;
    for my $key (@keys) {
        # sort numeric
        if(defined $data->[0]->{$key} and $data->[0]->{$key} =~ m/^\d+$/xm) {
            push @compares, '$a->{'.$key.'} <=> $b->{'.$key.'}';
        }
        # sort alphanumeric
        else {
            push @compares, '$a->{'.$key.'} cmp $b->{'.$key.'}';
        }
    }
    my $sortstring = join(' || ', @compares);
    $c->log->debug("ordering by: ".$sortstring);

    if(uc $order eq 'ASC') {
        eval '@sorted = sort { '.$sortstring.' } @{$data};';
    } else {
        eval '@sorted = reverse sort { '.$sortstring.' } @{$data};';
    }

    $c->stats->profile(end => "Helper::sort()");

    return(\@sorted);
}

############################################################
# get_service_exectution_stats
#
# Returns a hash with statistical data
#
sub get_service_exectution_stats {
    my $self            = shift;
    my $c               = shift;

    $c->stats->profile(begin => "Helper::get_service_exectution_stats()");

    my $now    = time();
    my $min1   = $now - 60;
    my $min5   = $now - 300;
    my $min15  = $now - 900;
    my $min60  = $now - 3600;

    my $check_stats;
    for my $type (qw{hosts services}) {
        $check_stats->{$type} = {
            'active_sum'                => 0,
            'active_1_min'              => 0,
            'active_5_min'              => 0,
            'active_15_min'             => 0,
            'active_60_min'             => 0,
            'active_all_min'            => 0,

            'active_1_min_perc'         => 0,
            'active_5_min_perc'         => 0,
            'active_15_min_perc'        => 0,
            'active_60_min_perc'        => 0,
            'active_all_min_perc'       => 0,

            'execution_time_min'        => undef,
            'execution_time_max'        => undef,
            'execution_time_avg'        => 0,
            'execution_time_sum'        => 0,

            'latency_min'               => undef,
            'latency_max'               => undef,
            'latency_avg'               => 0,
            'latency_sum'               => 0,

            'active_state_change_min'   => undef,
            'active_state_change_max'   => undef,
            'active_state_change_avg'   => 0,
            'active_state_change_sum'   => 0,

            'passive_sum'               => 0,
            'passive_1_min'             => 0,
            'passive_5_min'             => 0,
            'passive_15_min'            => 0,
            'passive_60_min'            => 0,
            'passive_all_min'           => 0,

            'passive_1_min_perc'        => 0,
            'passive_5_min_perc'        => 0,
            'passive_15_min_perc'       => 0,
            'passive_60_min_perc'       => 0,
            'passive_all_min_perc'      => 0,

            'passive_state_change_min'  => undef,
            'passive_state_change_max'  => undef,
            'passive_state_change_avg'  => 0,
            'passive_state_change_sum'  => 0,
        };

        for my $data (@{$c->{'live'}->selectall_arrayref("GET $type\nColumns: execution_time has_been_checked last_check latency percent_state_change check_type", { Slice => 1, AddPeer => 1 })}) {
            my $minall = $c->stash->{'pi_detail'}->{$data->{'peer_name'}}->{'program_start'};

            if($data->{'check_type'} == 0) {
                $check_stats->{$type}->{'active_sum'}++;
            } else {
                $check_stats->{$type}->{'passive_sum'}++;
            }

            if($data->{'has_been_checked'}) {

                # active checks
                if($data->{'check_type'} == 0) {
                    if($data->{'last_check'} >= $min1)   { $check_stats->{$type}->{'active_1_min'}++;   }
                    if($data->{'last_check'} >= $min5)   { $check_stats->{$type}->{'active_5_min'}++;   }
                    if($data->{'last_check'} >= $min15)  { $check_stats->{$type}->{'active_15_min'}++;  }
                    if($data->{'last_check'} >= $min60)  { $check_stats->{$type}->{'active_60_min'}++;  }
                    if($data->{'last_check'} >= $minall) { $check_stats->{$type}->{'active_all_min'}++; }

                    # sum up all values to calculate averages later
                    $check_stats->{$type}->{'execution_time_sum'}       += $data->{'execution_time'};
                    $check_stats->{$type}->{'latency_sum'}              += $data->{'latency'};
                    $check_stats->{$type}->{'active_state_change_sum'}  += $data->{'percent_state_change'};

                    # check min/max values
                    if(!defined $check_stats->{$type}->{'execution_time_min'} or $check_stats->{$type}->{'execution_time_min'} > $data->{'execution_time'}) {
                        $check_stats->{$type}->{'execution_time_min'} = $data->{'execution_time'};
                    }
                    if(!defined $check_stats->{$type}->{'execution_time_max'} or $check_stats->{$type}->{'execution_time_max'} < $data->{'execution_time'}) {
                        $check_stats->{$type}->{'execution_time_max'} = $data->{'execution_time'};
                    }

                    if(!defined $check_stats->{$type}->{'latency_min'} or $check_stats->{$type}->{'latency_min'} > $data->{'latency'}) {
                        $check_stats->{$type}->{'latency_min'} = $data->{'latency'};
                    }
                    if(!defined $check_stats->{$type}->{'latency_max'} or $check_stats->{$type}->{'latency_max'} < $data->{'latency'}) {
                        $check_stats->{$type}->{'latency_max'} = $data->{'latency'};
                    }

                    if(!defined $check_stats->{$type}->{'active_state_change_min'} or $check_stats->{$type}->{'active_state_change_min'} > $data->{'percent_state_change'}) {
                        $check_stats->{$type}->{'active_state_change_min'} = $data->{'percent_state_change'};
                    }
                    if(!defined $check_stats->{$type}->{'active_state_change_max'} or $check_stats->{$type}->{'active_state_change_max'} < $data->{'percent_state_change'}) {
                        $check_stats->{$type}->{'active_state_change_max'} = $data->{'percent_state_change'};
                    }
                }
                # passive checks
                else {
                    $check_stats->{$type}->{'passive_sum'}++;
                    if($data->{'last_check'} >= $min1)   { $check_stats->{$type}->{'passive_1_min'}++;   }
                    if($data->{'last_check'} >= $min5)   { $check_stats->{$type}->{'passive_5_min'}++;   }
                    if($data->{'last_check'} >= $min15)  { $check_stats->{$type}->{'passive_15_min'}++;  }
                    if($data->{'last_check'} >= $min60)  { $check_stats->{$type}->{'passive_60_min'}++;  }
                    if($data->{'last_check'} >= $minall) { $check_stats->{$type}->{'passive_all_min'}++; }

                    # sum up all values to calculate averages later
                    $check_stats->{$type}->{'passive_state_change_sum'} += $data->{'percent_state_change'};

                    # check min/max values
                    if(!defined $check_stats->{$type}->{'passive_state_change_min'} or $check_stats->{$type}->{'passive_state_change_min'} > $data->{'percent_state_change'}) {
                        $check_stats->{$type}->{'active_state_change_min'} = $data->{'percent_state_change'};
                    }
                    if(!defined $check_stats->{$type}->{'passive_state_change_max'} or $check_stats->{$type}->{'passive_state_change_max'} < $data->{'percent_state_change'}) {
                        $check_stats->{$type}->{'passive_state_change_max'} = $data->{'percent_state_change'};
                    }
                }
            }
        }

        # calculate averages
        if($check_stats->{$type}->{'active_sum'} > 0) {
            $check_stats->{$type}->{'execution_time_avg'}       = $check_stats->{$type}->{'execution_time_sum'}       / $check_stats->{$type}->{'active_sum'};
            $check_stats->{$type}->{'latency_avg'}              = $check_stats->{$type}->{'latency_sum'}              / $check_stats->{$type}->{'active_sum'};
            $check_stats->{$type}->{'active_state_change_avg'}  = $check_stats->{$type}->{'active_state_change_sum'}  / $check_stats->{$type}->{'active_sum'};
        } else {
            $check_stats->{$type}->{'execution_time_avg'}       = 0;
            $check_stats->{$type}->{'latency_avg'}              = 0;
            $check_stats->{$type}->{'active_state_change_avg'}  = 0;
        }
        if($check_stats->{$type}->{'passive_sum'} > 0) {
            $check_stats->{$type}->{'passive_state_change_avg'} = $check_stats->{$type}->{'passive_state_change_sum'} / $check_stats->{$type}->{'passive_sum'};
        } else {
            $check_stats->{$type}->{'passive_state_change_avg'} = 0;
        }

        # calculate percentages
        if($check_stats->{$type}->{'active_sum'} > 0) {
            $check_stats->{$type}->{'active_1_min_perc'}   = $check_stats->{$type}->{'active_1_min'}   / $check_stats->{$type}->{'active_sum'} * 100;
            $check_stats->{$type}->{'active_5_min_perc'}   = $check_stats->{$type}->{'active_5_min'}   / $check_stats->{$type}->{'active_sum'} * 100;
            $check_stats->{$type}->{'active_15_min_perc'}  = $check_stats->{$type}->{'active_15_min'}  / $check_stats->{$type}->{'active_sum'} * 100;
            $check_stats->{$type}->{'active_60_min_perc'}  = $check_stats->{$type}->{'active_60_min'}  / $check_stats->{$type}->{'active_sum'} * 100;
            $check_stats->{$type}->{'active_all_min_perc'} = $check_stats->{$type}->{'active_all_min'} / $check_stats->{$type}->{'active_sum'} * 100;
        }

        if($check_stats->{$type}->{'passive_sum'} > 0) {
            $check_stats->{$type}->{'passive_1_min_perc'}   = $check_stats->{$type}->{'passive_1_min'}   / $check_stats->{$type}->{'passive_sum'} * 100;
            $check_stats->{$type}->{'passive_5_min_perc'}   = $check_stats->{$type}->{'passive_5_min'}   / $check_stats->{$type}->{'passive_sum'} * 100;
            $check_stats->{$type}->{'passive_15_min_perc'}  = $check_stats->{$type}->{'passive_15_min'}  / $check_stats->{$type}->{'passive_sum'} * 100;
            $check_stats->{$type}->{'passive_60_min_perc'}  = $check_stats->{$type}->{'passive_60_min'}  / $check_stats->{$type}->{'passive_sum'} * 100;
            $check_stats->{$type}->{'passive_all_min_perc'} = $check_stats->{$type}->{'passive_all_min'} / $check_stats->{$type}->{'passive_sum'} * 100;
        }
    }

    $c->stats->profile(end => "Helper::get_service_exectution_stats()");

    return($check_stats);
}

########################################
sub _get_hostcomments {
    my $self            = shift;
    my $c               = shift;
    my $filter          = shift;

    $c->stats->profile(begin => "Helper::_get_hostcomments()");

    $filter = '' unless defined $filter;
    my $hostcomments;
    my $comments    = $c->{'live'}->selectall_arrayref("GET comments\n$filter\nFilter: service_description =\nColumns: host_name id", { Slice => 1 });

    for my $comment (@{$comments}) {
        $hostcomments->{$comment->{'host_name'}}->{$comment->{'id'}} = $comment;
    }

    $c->stats->profile(end => "Helper::_get_hostcomments()");

    return $hostcomments;
}

########################################
sub _get_servicecomments {
    my $self            = shift;
    my $c               = shift;
    my $filter          = shift;

    $c->stats->profile(begin => "Helper::_get_servicecomments()");

    my $servicecomments;
    my $comments = $c->{'live'}->selectall_arrayref("GET comments\n$filter\nFilter: service_description !=\nColumns: host_name service_description id", { Slice => 1 });

    for my $comment (@{$comments}) {
        $servicecomments->{$comment->{'host_name'}}->{$comment->{'service_description'}}->{$comment->{'id'}} = $comment;
    }

    $c->stats->profile(end => "Helper::_get_servicecomments()");

    return $servicecomments;
}

########################################
sub _get_livesocket_path_from_nagios_cfg {
    my $self            = shift;
    my $nagios_cfg_path = shift;

    if(!-r $nagios_cfg_path) {
        confess('cannot read your '.$nagios_cfg_path.'. please specify a livesocket_path in your nagios_web.conf');
    }

    # read nagios.cfg
    my $conf       = new Config::General($nagios_cfg_path);
    my %nagios_cfg = $conf->getall;

    if(!defined $nagios_cfg{'broker_module'}) {
        confess('cannot find a livestatus socket path in your '.$nagios_cfg_path.'. No livestatus broker module loaded?');
    }

    my @broker;
    if(ref $nagios_cfg{'broker_module'} eq 'ARRAY') {
        @broker = [$nagios_cfg{'broker_module'}];
    }else {
        push @broker, $nagios_cfg{'broker_module'};
    }

    for my $neb_line (@broker) {
        if($neb_line =~ m/livestatus.o\s+(.*?)$/) {
            my $livesocket_path = $1;
            return($livesocket_path);
        }
    }

    confess('cannot find a livestatus socket path in your '.$nagios_cfg_path.'. No livestatus broker module loaded?');
}

########################################
sub _calculate_overall_processinfo {
    my $self = shift;
    my $pi   = shift;
    my $return;
    for my $peer (keys %{$pi}) {
        for my $key (keys %{$pi->{$peer}}) {
            my $value = $pi->{$peer}->{$key};
            if($value eq "0" or $value eq "1") {
                if(!defined $return->{$key}) {
                    $return->{$key} = $value;
                }elsif($return->{$key} == -1) {
                    # do nothing, result already varies
                }elsif($return->{$key} == $value) {
                    # do nothing, result is the same
                }elsif($return->{$key} != $value) {
                    # set result to vary
                    $return->{$key} = -1;
                }
            }
        }
    }
    return($return);
}

1;
