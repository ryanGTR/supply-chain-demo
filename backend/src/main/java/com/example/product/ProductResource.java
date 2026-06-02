package com.example.product;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;

import java.util.List;

@Path("/products")
@ApplicationScoped
public class ProductResource {

    @GET
    @Produces(MediaType.APPLICATION_JSON)
    public List<Product> list() {
        return List.of(
                new Product(1, "Coffee", 4.5),
                new Product(2, "Bagel", 3.0),
                new Product(3, "Sandwich", 8.5)
        );
    }
}
