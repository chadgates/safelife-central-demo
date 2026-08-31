/* global angular */
(function () {
  'use strict';

  angular
    .module('safelife', [])
    .controller('MessagesController', ['$http', '$interval', function ($http, $interval) {
      var vm = this;

      vm.messages = [];
      vm.status = {};
      vm.error = null;
      vm.pollSeconds = 2;

      // The brief says "always show the last 100", so the client asks for exactly that
      // and the server clamps to 100 as well. No paging, no incremental sync - polling a
      // bounded list keeps both sides stateless and is honest about what this demo is.
      function refresh() {
        $http.get('api/messages?limit=100')
          .then(function (res) {
            vm.messages = res.data;
            vm.error = null;
          })
          .catch(function (res) {
            vm.error = 'Cannot reach the backend (HTTP ' + (res.status || 0) + ')';
          });

        $http.get('api/status')
          .then(function (res) { vm.status = res.data; })
          .catch(function () { /* the messages call already surfaces the error */ });
      }

      refresh();
      $interval(refresh, vm.pollSeconds * 1000);
    }]);
})();
