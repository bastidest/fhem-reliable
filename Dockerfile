# debian:buster @ 2020-07-03 12:17:30
FROM debian@sha256:46d659005ca1151087efa997f1039ae45a7bf7a2cbbe2d17d3dcbda632a3ee9a

RUN apt-get update && apt-get install -y perl curl procps supervisor 

RUN curl -o /opt/fhem.tar.gz http://fhem.de/fhem-6.0.tar.gz \
	&& cd /opt/ \
	&& tar -xf fhem.tar.gz \
	&& mv fhem-6.0 fhem

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
CMD ["/usr/bin/supervisord"]
