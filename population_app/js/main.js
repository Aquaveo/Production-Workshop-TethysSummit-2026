$(document).ready(function() {
    // Custom properties generator function
    function customPropertiesGenerator(feature, layer) {
        return "<table class='table table-striped table-bordered table-condensed'>" + 
            "<tr><td>Country Name</td><td>" + feature.A.ADMIN + "</td></tr>" +
            "<tr><td>Country Code</td><td>" + feature.A.ISO_A3 + "</td></tr>" +
            
            "</table>";
    }
    // Assign the custom properties generator to the MAP_LAYOUT object
    MAP_LAYOUT.properties_table_generator(customPropertiesGenerator);
});
