# openstack-instance-monitor

`imon` - A (super)nova instance monitor for OpenStack cloud environments

A simple monitoring facility which will retrieve a list of running hosts via
the `nova` API, and report any changes to a nominated twitter account.
Twitter alerting could be trivially exchanged for any other reporting
mechanism - but posting tweets to a project-specific private account is a great
replacement for an SMS alerting system, and with bonus rate-limiting if things
massively break ;)

`imon` requires [stdlib.sh](/srcshelton/stdlib.sh), as well as [tweet.pl](/srcshelton/tweet.pl) for alerting purposes.
