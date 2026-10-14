// Synthetic fixture: AngularJS controller for a simple badge picker.
angular.module("umbraco").controller("SampleSite.BadgeEditorController", function ($scope) {
    $scope.styles = ["new", "updated", "featured"];
    $scope.select = function (style) {
        $scope.model.value = style;
    };
});
