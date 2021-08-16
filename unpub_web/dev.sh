#!/bin/bash
dart pub global activate webdev 2.7.4
dart pub global activate webdev_proxy 0.1.1
dart pub global run webdev_proxy serve -- --auto=refresh --log-requests
