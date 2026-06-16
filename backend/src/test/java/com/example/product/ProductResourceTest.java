package com.example.product;

import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Unit tests for {@link ProductResource}.
 *
 * <p>These run as part of the supply-chain {@code test} gate (mvn test). A passing,
 * non-empty suite is the evidence behind "promote what passed test" — see
 * itops {@code scripts/verify_deploy_gate.py} check 4.</p>
 */
class ProductResourceTest {

    private final ProductResource resource = new ProductResource();

    @Test
    void listReturnsAllProducts() {
        List<Product> products = resource.list();
        assertEquals(3, products.size(), "catalogue should expose three products");
    }

    @Test
    void coffeeHasExpectedIdAndPrice() {
        Product coffee = resource.list().stream()
                .filter(p -> p.name().equals("Coffee"))
                .findFirst()
                .orElseThrow();
        assertEquals(1L, coffee.id());
        assertEquals(4.5, coffee.price());
    }

    @Test
    void productIdsAreUnique() {
        List<Product> products = resource.list();
        long distinctIds = products.stream().map(Product::id).distinct().count();
        assertEquals(products.size(), distinctIds, "product ids must be unique");
        assertTrue(products.stream().allMatch(p -> p.price() > 0), "prices must be positive");
    }
}
