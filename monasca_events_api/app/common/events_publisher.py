# Copyright 2018 FUJITSU LIMITED
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

import falcon
from monasca_common.kafka import producer
from monasca_common.kafka_lib.common import FailedPayloadsError
from monasca_common.rest import utils as rest_utils
from monasca_events_api import conf
from monasca_events_api.app.model import envelope as ev_envelope
from oslo_log import log


LOG = log.getLogger(__name__)
CONF = conf.CONF

_RETRY_AFTER = 60
_KAFKA_META_DATA_SIZE = 32
_TRUNCATION_SAFE_OFFSET = 1


class InvalidMessageException(Exception):
    pass


class EventPublisher(object):
    """Publishes events data to Kafka

    EventPublisher is able to send single message to multiple configured topic.
    It uses following configuration written in conf file ::

        [event_publisher]
        topics = 'monevents'
        kafka_url = 'localhost:8900'

    Note:
        Uses :py:class:`monasca_common.kafka.producer.KafkaProducer`
        to ship events to kafka. For more details
        see `monasca-common`_ github repository.

    .. _monasca-common: https://github.com/openstack/monasca-common

    """

    def __init__(self):

        self._topics = CONF.events_publisher.topics

        self._kafka_publisher = producer.KafkaProducer(
            url=CONF.events_publisher.kafka_url
        )

        LOG.info('Initializing EventPublisher <%s>', self)

    def send_message(self, messages):
        """Sends message to each configured topic.

        Note:
            Empty content is not shipped to kafka

        :param dict| list messages:
        """
        if not messages:
            return
        if not isinstance(messages, list):
            messages = [messages]

        sent_counter = 0
        num_of_msgs = len(messages)

        LOG.debug('About to publish %d messages to %s topics',
                  num_of_msgs, self._topics)

        send_messages = []

        for message in messages:
            try:
                msg = self._transform_message(message)
                send_messages.append(msg)
            except Exception as ex:
                LOG.exception(
                    'Failed to transform message, '
                    'this massage is dropped {} '
                    'Exception: {}'.format(message, str(ex)))
        try:
            self._publish(send_messages)
            sent_counter = len(send_messages)
        except Exception as ex:
            LOG.exception('Failure in publishing messages to kafka')
            raise ex
        finally:
            self._check_if_all_messages_was_publish(sent_counter, num_of_msgs)

    def _transform_message(self, message):
        """Transforms message into JSON.

        Method transforms message to JSON and
        encode to utf8
        :param str message: instance of message
        :return: serialized message
        :rtype: str
        """
        if not self._is_message_valid(message):
            raise InvalidMessageException()

        truncated = self._truncate(message)
        proper = self._ensure_type_bytes(truncated)
        return proper

    def _truncate(self, envelope):
        """
        :param Envelope envelope: original envelope
        :return: serialized message
        :rtype: str
        """
        msg_str = ev_envelope.serialize_envelope(envelope)
        return msg_str

    def _ensure_type_bytes(self, message):
        """Ensures that message will have proper type.

        :param str message: instance of message

        """
        return message.encode('utf-8')

    def _publish(self, messages):
        """Publishes messages to kafka.
        :param list messages: list of messages
        """
        num_of_msg = len(messages)

        LOG.debug('Publishing %d messages', num_of_msg)

        try:
            for topic in self._topics:
                self._kafka_publisher.publish(
                    topic,
                    messages
                )
                LOG.debug('Sent %d messages to topic %s', num_of_msg, topic)
        except Exception as ex:
            raise falcon.HTTPServiceUnavailable('Service unavailable',
                                                str(ex), 60)

    @staticmethod
    def _is_message_valid(message):
        """Validates message before sending.

        Methods checks if message is :py:class:`model.envelope.Envelope`.
        By being instance of this class it is ensured that all required
        keys are found and they will have their values.

        """
        return message and isinstance(message, ev_envelope.Envelope)

    def _check_if_all_messages_was_publish(self, send_count, to_send_count):
        """Executed after publishing to sent metrics.

        :param int send_count: how many messages have been sent
        :param int to_send_count: how many messages should be sent

        """
        failed_to_send = to_send_count - send_count

        if failed_to_send == 0:
            LOG.debug('Successfully published all [%d] messages',
                      send_count)
        else:
            error_str = ('Failed to send all messages, %d '
                         'messages out of %d have not been published')
            LOG.error(error_str, failed_to_send, to_send_count)
